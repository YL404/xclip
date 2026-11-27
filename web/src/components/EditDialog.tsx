import { useEffect, useRef, useState } from "preact/hooks";
import type { Entry, Patch } from "../mygo";
import { Icon } from "./Icons";

interface EditDialogProps {
  open: boolean;
  entry: Entry | null;
  onSave: (id: string, patch: Patch) => Promise<void>;
  onClose: () => void;
}

export function EditDialog({ open, entry, onSave, onClose }: EditDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const formRef = useRef<HTMLFormElement>(null);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && entry) {
      const form = formRef.current;
      if (form) {
        const fields: Record<string, string> = {
          title: entry.title,
          summary: entry.summary,
          note: entry.note,
          tags: entry.tags.join(", "),
        };
        for (const [name, value] of Object.entries(fields)) {
          const control = form.elements.namedItem(name) as HTMLInputElement | HTMLTextAreaElement | null;
          if (control) control.value = value;
        }
      }
      setError("");
      if (!dialog.open) dialog.showModal();
    } else if (dialog.open) {
      dialog.close();
    }
  }, [open, entry]);

  const handleSubmit = async (event: SubmitEvent) => {
    event.preventDefault();
    if (!entry || saving || !formRef.current) return;
    setSaving(true);
    setError("");
    const readField = (name: string) =>
      (formRef.current?.elements.namedItem(name) as HTMLInputElement | HTMLTextAreaElement | null)
        ?.value ?? "";
    const patch: Patch = {
      title: readField("title"),
      summary: readField("summary"),
      note: readField("note"),
      tags: readField("tags")
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean),
      asset_texts: {},
    };
    try {
      await onSave(entry.id, patch);
      onClose();
    } catch (err) {
      setError(String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <dialog
      ref={dialogRef}
      class="edit-dialog"
      id="edit-dialog"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <form ref={formRef} id="edit-form" onSubmit={handleSubmit}>
        <div class="dialog-head">
          <h2>编辑内容</h2>
          <button
            type="button"
            class="icon-btn"
            id="close-edit"
            aria-label="关闭编辑"
            onClick={onClose}
          >
            <Icon name="close" />
          </button>
        </div>

        <label>
          标题
          <input name="title" required />
        </label>

        <label>
          英文摘要
          <textarea
            name="summary"
            rows={4}
            placeholder="用一至两句英文概括内容"
          />
          <small>单行英文，不超过 400 字符。</small>
        </label>

        <label>
          个人备注
          <textarea name="note" rows={3} />
        </label>

        <label>
          标签
          <input name="tags" placeholder="swiftui, interaction:交互设计" />
          <small>逗号分隔；已有标签使用英文 slug，新标签使用 slug:中文名称。</small>
        </label>

        <div id="edit-error" class="form-error" role="alert">
          {error}
        </div>

        <div class="dialog-actions">
          <button type="button" id="cancel-edit" class="soft-button" onClick={onClose}>
            取消
          </button>
          <button type="submit" class="primary-button" id="save-edit" disabled={saving}>
            保存更改
          </button>
        </div>
      </form>
    </dialog>
  );
}
