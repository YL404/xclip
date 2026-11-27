import { useEffect, useRef } from "preact/hooks";
import { Icon } from "./Icons";

interface InfoDialogProps {
  open: boolean;
  onClose: () => void;
}

export function InfoDialog({ open, onClose }: InfoDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open) {
      if (!dialog.open) dialog.showModal();
    } else if (dialog.open) {
      dialog.close();
    }
  }, [open]);

  return (
    <dialog
      ref={dialogRef}
      class="info-dialog"
      id="info-dialog"
      aria-labelledby="info-title"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <header class="info-head">
        <h2 id="info-title">阅读与检索</h2>
        <button class="icon-btn" id="info-close" aria-label="关闭说明" onClick={onClose}>
          <Icon name="close" />
        </button>
      </header>
      <p>一条内容可以同时保存说明、代码、图片和视频。通过标签或关键词找回内容，直接打开命中的文件。</p>
      <p>网格视图用于快速浏览画面，列表视图按日期展开标题、摘要与标签。文件和文件夹可通过收录按钮或拖入窗口添加。</p>
      <div class="shortcut-list">
        <span>搜索内容</span>
        <kbd>⌘ / Ctrl K</kbd>
        <span>打开选中的内容</span>
        <kbd>空格 / Enter</kbd>
        <span>上一条 / 下一条</span>
        <kbd>← / →</kbd>
        <span>关闭阅读</span>
        <kbd>Esc</kbd>
      </div>
    </dialog>
  );
}
