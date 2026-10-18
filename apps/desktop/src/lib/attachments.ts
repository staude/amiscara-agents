// Files for a prompt, by the rules of the Apple apps (#116, #121): images
// agents read directly go up as they are up to 4 MB, other or larger images
// become JPEG (at most 2560 px), any other file goes up under its own name
// up to 20 MB.

export interface Attachment {
  id: number;
  data: Uint8Array;
  /** Set for a file kept under its name; images use `extension`. */
  fileName: string | null;
  extension: string;
  /** Object URL of an image preview. */
  preview: string | null;
}

const PASS_THROUGH: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
};
const MAX_IMAGE_BYTES = 4_000_000;
const MAX_PIXELS = 2560;
const MAX_FILE_BYTES = 20_000_000;

let nextId = 1;

async function toJpeg(file: Blob): Promise<Uint8Array | null> {
  try {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, MAX_PIXELS / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext("2d")?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
    return blob ? new Uint8Array(await blob.arrayBuffer()) : null;
  } catch {
    return null;
  }
}

/** Prepares a picked, pasted or dropped file; throws a German message. */
export async function prepare(file: File): Promise<Attachment> {
  const name = file.name || "Die Datei";
  if (file.type.startsWith("image/")) {
    const kept = PASS_THROUGH[file.type];
    const preview = URL.createObjectURL(file);
    if (kept && file.size <= MAX_IMAGE_BYTES) {
      return { id: nextId++, data: new Uint8Array(await file.arrayBuffer()), fileName: null, extension: kept, preview };
    }
    const jpeg = await toJpeg(file);
    if (jpeg) return { id: nextId++, data: jpeg, fileName: null, extension: "jpg", preview };
    URL.revokeObjectURL(preview);
    // An image the webview cannot decode (e.g. HEIC) goes up as a file.
  }
  if (file.size > MAX_FILE_BYTES) throw new Error(`${name} ist größer als 20 MB.`);
  let data: Uint8Array;
  try {
    data = new Uint8Array(await file.arrayBuffer());
  } catch {
    throw new Error(`${name} lässt sich nicht lesen.`);
  }
  const extension = name.includes(".") ? name.split(".").pop()! : "";
  return { id: nextId++, data, fileName: name, extension, preview: null };
}

export function release(attachment: Attachment) {
  if (attachment.preview) URL.revokeObjectURL(attachment.preview);
}

/** `'path'` with `'` written as `'\''`, for a shell. */
export function shellQuoted(path: string): string {
  return `'${path.replaceAll("'", "'\\''")}'`;
}
