import type { LibraryClient } from "./api";
import type { Asset } from "./mygo";
import { mediaURL } from "./view";

export interface MediaPreview {
  poster: string;
  duration: number;
}

function waitFor(video: HTMLVideoElement, event: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const finish = (error?: Error) => {
      clearTimeout(timer);
      video.removeEventListener(event, success);
      video.removeEventListener("error", failure);
      if (error) reject(error);
      else resolve();
    };
    const success = () => finish();
    const failure = () => finish(new Error("此视频暂不支持预览"));
    const timer = setTimeout(() => finish(new Error("读取视频超时")), 12000);
    video.addEventListener(event, success, { once: true });
    video.addEventListener("error", failure, { once: true });
  });
}

async function capture(client: LibraryClient, asset: Asset): Promise<MediaPreview> {
  const video = document.createElement("video");
  video.crossOrigin = "anonymous";
  video.muted = true;
  video.playsInline = true;
  video.preload = "auto";
  let duration = 0;
  try {
    const loaded = waitFor(video, "loadeddata");
    video.src = mediaURL(asset);
    await loaded;
    duration = Number.isFinite(video.duration) ? video.duration : 0;
    const position = Math.min(duration / 2, 10);
    if (position > 0) {
      const seeked = waitFor(video, "seeked");
      video.currentTime = position;
      await seeked;
    }
    duration = Number.isFinite(video.duration) ? video.duration : duration;
    if (!video.videoWidth || !video.videoHeight) throw new Error("视频画面不可用");
    // WebKit 在 seeked 后立刻 drawImage 偶尔会画到尚未合成的黑帧，等两帧再取画面。
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
    );
    const scale = Math.min(1, 640 / Math.max(video.videoWidth, video.videoHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
    canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
    canvas.getContext("2d")!.drawImage(video, 0, 0, canvas.width, canvas.height);
    const poster = canvas.toDataURL("image/jpeg", 0.85);
    try {
      await client.cachePreview(asset.id, poster, duration);
    } catch {
      return { poster, duration };
    }
    return { poster: mediaURL(asset, true), duration };
  } catch {
    return { poster: "", duration };
  } finally {
    video.removeAttribute("src");
    video.load();
  }
}

export interface AssetCache {
  getText(entryID: string, asset: Asset): Promise<string>;
  peekText(assetID: string): string | undefined;
  getPreview(asset: Asset): Promise<MediaPreview>;
  peekPreview(assetID: string): MediaPreview | undefined;
  queuePreview(work: () => Promise<void>): void;
  clear(): void;
}

/**
 * 统一管理每个应用实例的文本正文与视频封面缓存，避免模块级全局状态在刷新或测试间串扰。
 */
export function createAssetCache(client: LibraryClient): AssetCache {
  const textTasks = new Map<string, Promise<string>>();
  const texts = new Map<string, string>();
  const previewTasks = new Map<string, Promise<MediaPreview>>();
  const readyPreviews = new Map<string, MediaPreview>();
  const queue: Array<() => Promise<void>> = [];
  let running = 0;

  function pump(): void {
    while (running < 2 && queue.length) {
      const task = queue.shift()!;
      running++;
      void task()
        .catch(() => {})
        .finally(() => {
          running--;
          pump();
        });
    }
  }

  return {
    getText(entryID, asset) {
      let task = textTasks.get(asset.id);
      if (!task) {
        task = client
          .text(entryID, asset.path)
          .then((value) => {
            texts.set(asset.id, value);
            return value;
          })
          .catch((error: unknown) => {
            textTasks.delete(asset.id);
            throw error;
          });
        textTasks.set(asset.id, task);
      }
      return task;
    },
    peekText(assetID) {
      return texts.get(assetID);
    },
    getPreview(asset) {
      let task = previewTasks.get(asset.id);
      if (!task) {
        task = (async () => {
          try {
            const cached = await client.preview(asset.id);
            if (cached.poster) {
              return { poster: mediaURL(asset, true), duration: cached.duration };
            }
          } catch {
            // 缓存不可读时重新从库内原件解码。
          }
          return capture(client, asset);
        })().then((preview) => {
          readyPreviews.set(asset.id, preview);
          return preview;
        });
        previewTasks.set(asset.id, task);
      }
      return task;
    },
    peekPreview(assetID) {
      return readyPreviews.get(assetID);
    },
    queuePreview(work) {
      queue.push(work);
      pump();
    },
    clear() {
      textTasks.clear();
      texts.clear();
      previewTasks.clear();
      readyPreviews.clear();
    },
  };
}
