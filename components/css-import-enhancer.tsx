"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Upload } from "lucide-react";

import { ConfirmDialog } from "@/components/ui/modal";

const MAX_CSS_IMPORT_SIZE = 512 * 1024;
const SUPPORTED_EXTENSIONS = new Set(["css", "txt", "docx"]);

type PendingImport = {
  fileName: string;
  css: string;
};

function getExtension(fileName: string): string {
  const dot = fileName.lastIndexOf(".");
  return dot >= 0 ? fileName.slice(dot + 1).toLowerCase() : "";
}

function decodeXmlText(value: string): string {
  return value
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function normalizeImportedCSS(value: string): string {
  const normalized = value
    .replace(/^\uFEFF/, "")
    .replace(/\r\n?/g, "\n")
    .replace(/\u00a0/g, " ")
    .trim();

  const fencedBlocks = [...normalized.matchAll(/```(?:css)?\s*\n([\s\S]*?)```/gi)];
  const css = fencedBlocks.length > 0
    ? fencedBlocks.map((match) => match[1].trim()).filter(Boolean).join("\n\n")
    : normalized;

  if (!css) {
    throw new Error("文件中没有可导入的 CSS 内容");
  }
  return css;
}

async function readDocxText(file: File): Promise<string> {
  const { default: JSZip } = await import("jszip");
  const zip = await JSZip.loadAsync(await file.arrayBuffer());
  const documentXml = await zip.file("word/document.xml")?.async("string");
  if (!documentXml) {
    throw new Error("无法读取该 DOCX 文件");
  }

  return decodeXmlText(documentXml
    .replace(/<w:tab\b[^>]*\/>/g, "\t")
    .replace(/<w:br\b[^>]*\/>/g, "\n")
    .replace(/<\/w:p>/g, "\n")
    .replace(/<[^>]+>/g, ""));
}

async function readCSSImportFile(file: File): Promise<string> {
  const extension = getExtension(file.name);
  if (!SUPPORTED_EXTENSIONS.has(extension)) {
    if (extension === "doc") {
      throw new Error("暂不支持旧版 .doc，请另存为 .docx 或 .txt 后导入");
    }
    throw new Error("仅支持 .css、.txt 和 .docx 文件");
  }
  if (file.size > MAX_CSS_IMPORT_SIZE) {
    throw new Error("文件不能超过 512 KB");
  }

  const content = extension === "docx" ? await readDocxText(file) : await file.text();
  return normalizeImportedCSS(content);
}

function updateControlledTextarea(textarea: HTMLTextAreaElement, value: string): void {
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")?.set;
  valueSetter?.call(textarea, value);
  textarea.dispatchEvent(new Event("input", { bubbles: true }));
  textarea.focus();
}

function showNotice(message: string): void {
  window.dispatchEvent(new CustomEvent("global-notice", { detail: message }));
}

export function CSSImportEnhancer() {
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [headerSlot, setHeaderSlot] = useState<HTMLElement | null>(null);
  const [targetTextarea, setTargetTextarea] = useState<HTMLTextAreaElement | null>(null);
  const [portalTarget, setPortalTarget] = useState<HTMLElement | null>(null);
  const [pendingImport, setPendingImport] = useState<PendingImport | null>(null);

  useEffect(() => {
    const refreshTargets = () => {
      const cssShell = [...document.querySelectorAll<HTMLElement>(".page-shell")].find((shell) => (
        shell.querySelector<HTMLElement>(".page-title")?.textContent?.trim() === "CSS 变量"
      ));
      const nextSlot = cssShell?.querySelector<HTMLElement>(".page-header-right") ?? null;
      const nextTextarea = cssShell?.querySelector<HTMLTextAreaElement>("textarea.ui-textarea") ?? null;

      document.querySelectorAll<HTMLElement>("[data-css-import-placeholder]").forEach((placeholder) => {
        if (!nextSlot?.contains(placeholder)) {
          placeholder.style.display = "";
          delete placeholder.dataset.cssImportPlaceholder;
        }
      });

      const placeholder = nextSlot?.querySelector<HTMLElement>(":scope > span");
      if (placeholder) {
        placeholder.dataset.cssImportPlaceholder = "1";
        placeholder.style.display = "none";
      }

      setHeaderSlot((current) => current === nextSlot ? current : nextSlot);
      setTargetTextarea((current) => current === nextTextarea ? current : nextTextarea);
      setPortalTarget(cssShell?.closest<HTMLElement>(".phone-shell") ?? null);
    };

    refreshTargets();
    const observer = new MutationObserver(refreshTargets);
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });

    return () => {
      observer.disconnect();
      document.querySelectorAll<HTMLElement>("[data-css-import-placeholder]").forEach((placeholder) => {
        placeholder.style.display = "";
        delete placeholder.dataset.cssImportPlaceholder;
      });
    };
  }, []);

  const handleFileChange = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;

    try {
      const css = await readCSSImportFile(file);
      setPendingImport({ fileName: file.name, css });
    } catch (error) {
      console.error("[GlobalCSS] import failed:", error);
      showNotice(error instanceof Error ? error.message : "CSS 文件读取失败");
    }
  }, []);

  const handleConfirmImport = useCallback(() => {
    if (!pendingImport || !targetTextarea?.isConnected) {
      setPendingImport(null);
      showNotice("CSS 页面已关闭，请重新打开后导入");
      return;
    }

    updateControlledTextarea(targetTextarea, pendingImport.css);
    setPendingImport(null);
    showNotice("CSS 已导入，请检查后点击「应用」");
  }, [pendingImport, targetTextarea]);

  return (
    <>
      <input
        ref={fileInputRef}
        type="file"
        accept=".css,.txt,.docx,text/css,text/plain,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        className="hidden"
        onChange={handleFileChange}
      />

      {headerSlot && createPortal(
        <button
          type="button"
          className="page-back-btn"
          aria-label="导入 CSS 文件"
          title="导入 CSS 文件"
          onClick={() => fileInputRef.current?.click()}
        >
          <Upload size={21} strokeWidth={1.6} />
        </button>,
        headerSlot
      )}

      {pendingImport && portalTarget && createPortal(
        <ConfirmDialog
          title="导入 CSS"
          message={`将导入「${pendingImport.fileName}」，并覆盖输入框中的现有内容。是否继续？`}
          icon={Upload}
          variant="action"
          confirmLabel="确认导入"
          cancelLabel="取消"
          onConfirm={handleConfirmImport}
          onCancel={() => setPendingImport(null)}
        />,
        portalTarget
      )}
    </>
  );
}
