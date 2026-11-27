import { useEffect, useRef } from "preact/hooks";
import type { Asset } from "../mygo";
import { mediaURL } from "../view";
import { Icon } from "./Icons";

interface ImageLightboxProps {
  open: boolean;
  images: Asset[];
  index: number;
  onStep: (direction: -1 | 1) => void;
  onClose: () => void;
}

export function ImageLightbox({ open, images, index, onStep, onClose }: ImageLightboxProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const current = images[index];

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && current) {
      if (!dialog.open) dialog.showModal();
    } else if (dialog.open) {
      dialog.close();
    }
  }, [open, current]);

  return (
    <dialog
      ref={dialogRef}
      class="image-view"
      id="image-view"
      aria-label="放大图片"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <div class="image-shell">
        <header class="image-toolbar">
          <span id="image-title">
            {current ? `${current.path} · ${index + 1} / ${images.length}` : ""}
          </span>
          <button
            class="icon-btn"
            id="image-prev"
            aria-label="上一张图片"
            disabled={index <= 0}
            onClick={() => onStep(-1)}
          >
            <Icon name="left" />
          </button>
          <button
            class="icon-btn"
            id="image-next"
            aria-label="下一张图片"
            disabled={index < 0 || index >= images.length - 1}
            onClick={() => onStep(1)}
          >
            <Icon name="right" />
          </button>
          <button
            class="icon-btn"
            id="image-close"
            aria-label="关闭放大图片"
            onClick={onClose}
          >
            <Icon name="close" />
          </button>
        </header>
        <div class="image-canvas">
          {current && (
            <img
              id="large-image"
              src={mediaURL(current)}
              alt={current.path}
              onClick={onClose}
            />
          )}
        </div>
      </div>
    </dialog>
  );
}
