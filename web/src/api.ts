import { onFileDrop } from "mygo-runtime";
import { Library, events } from "./mygo";
import type { Entry, Patch, Preview, SearchResult, Tag } from "./mygo";

export type Unsubscribe = () => void;

export interface LibraryClient {
  search(query: string, tags: string[], kind: string): Promise<SearchResult[]>;
  get(id: string): Promise<Entry>;
  text(id: string, path: string): Promise<string>;
  tags(): Promise<Tag[]>;
  update(id: string, patch: Patch): Promise<Entry>;
  importPaths(paths: string[]): Promise<Entry>;
  chooseAndImport(): Promise<Entry>;
  chooseFilesAndImport(): Promise<Entry>;
  copy(value: string): Promise<void>;
  reveal(assetID: string): Promise<void>;
  preview(assetID: string): Promise<Preview>;
  cachePreview(assetID: string, poster: string, duration: number): Promise<void>;
  onLibraryChanged(listener: () => void): Unsubscribe;
  onFileDrop(listener: (paths: string[]) => void): Unsubscribe;
}

export function createMyGoClient(): LibraryClient {
  return {
    search: (query, tags, kind) => Library.search(query, tags, kind),
    get: (id) => Library.get(id),
    text: (id, path) => Library.text(id, path),
    tags: () => Library.tags(),
    update: (id, patch) => Library.update(id, patch),
    importPaths: (paths) => Library.import(paths),
    chooseAndImport: () => Library.chooseAndImport(),
    chooseFilesAndImport: () => Library.chooseFilesAndImport(),
    copy: (value) => Library.copy(value),
    reveal: (assetID) => Library.reveal(assetID),
    preview: (assetID) => Library.preview(assetID),
    cachePreview: (assetID, poster, duration) => Library.cachePreview(assetID, poster, duration),
    onLibraryChanged: (listener) => {
      const off = events.libraryChanged.on(listener);
      return typeof off === "function" ? off : () => {};
    },
    onFileDrop: (listener) => {
      const off = onFileDrop(({ paths }) => {
        if (paths.length) listener(paths);
      });
      return typeof off === "function" ? off : () => {};
    },
  };
}
