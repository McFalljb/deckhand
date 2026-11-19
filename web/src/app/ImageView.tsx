// A file tab of an image (image.ts says which): the picture, read-only, centred, shrunk to fit and
// never enlarged, over a checkerboard, its type, pixels and size under it. The bytes come from
// file_read with image (the core's rules for a browser's reads, at most 8 MB), followed on disk as
// text tabs are (its hash: an unchanged file sends nothing). Shown only through an <img> of a blob:
// URL typed by the core from the bytes, revoked when replaced or unmounted: nothing of a file is
// ever put in the page as markup (an SVG's scripts never run in an <img>).

import { useEffect, useState } from "preact/hooks";
import { useApp } from "./ctx.ts";
import { Icon } from "./icons.tsx";
import { fromBase64, imageCaption } from "./image.ts";

const json = (d: unknown): any => (typeof d === "string" ? JSON.parse(d) : (d ?? {}));

interface Pic {
  url: string;
  mime: string;
  size: number;
}

// A blob: URL for these bytes while the component shows them (revoked on change and unmount).
function useBlobUrl(bytes: BlobPart | null, mime: string): string {
  const [url, setUrl] = useState("");
  useEffect(() => {
    if (bytes === null) return setUrl("");
    const u = URL.createObjectURL(new Blob([bytes], { type: mime }));
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [bytes, mime]);
  return url;
}

// The picture and its caption, or "can't display" when the browser cannot decode it. Keyed by its
// URL (Picture below): a new picture starts with no size and not broken.
function PictureOf({ pic, name }: { pic: Pic; name: string }) {
  const [dims, setDims] = useState<[number, number]>([0, 0]);
  const [broken, setBroken] = useState(false);
  if (broken) return <div class="ch-msg"><div>Can't display this image</div><div class="muted-text small">{name}</div></div>;
  return (
    <div class="img-view">
      <div class="img-box">
        {pic.url ? (
          <img
            src={pic.url}
            alt={name}
            draggable={false}
            onLoad={(e) => setDims([(e.currentTarget as HTMLImageElement).naturalWidth, (e.currentTarget as HTMLImageElement).naturalHeight])}
            onError={() => setBroken(true)}
          />
        ) : null}
      </div>
      <div class="img-cap muted-text small">{imageCaption(pic.mime, pic.size, dims[0], dims[1])}</div>
    </div>
  );
}

function Picture({ pic, name }: { pic: Pic; name: string }) {
  return <PictureOf key={pic.url} pic={pic} name={name} />;
}

// An SVG tab's preview: its text (already read as text) as an image.
export function SvgPreview({ text, name }: { text: string; name: string }) {
  const url = useBlobUrl(text, "image/svg+xml");
  return <Picture pic={{ url, mime: "image/svg+xml", size: new TextEncoder().encode(text).length }} name={name} />;
}

// A PNG, JPEG, GIF, BMP or WebP file's tab.
export function ImageTab({ path }: { path: string }) {
  const app = useApp();
  const [got, setGot] = useState<{ bytes: Uint8Array; mime: string; size: number } | null>(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    setGot(null);
    setErr("");
    let live = true;
    let busy = false;
    let hash = "";
    const read = async () => {
      if (busy) return;
      busy = true;
      const r = await app.link.run({ type: "file_read", path, image: true, since: hash }).finally(() => (busy = false));
      if (!live) return;
      if (!r.ok) return setErr(r.error || "cannot read it");
      const d = json(r.data);
      setErr("");
      if (d.same || typeof d.base64 !== "string") return;
      hash = d.hash;
      setGot({ bytes: fromBase64(d.base64), mime: d.image, size: d.size });
    };
    read();
    const t = window.setInterval(read, 2500);
    return () => {
      live = false;
      window.clearInterval(t);
    };
  }, [path]);
  const url = useBlobUrl(got ? (got.bytes as BlobPart) : null, got?.mime ?? "");
  const name = path.slice(path.lastIndexOf("/") + 1);
  return (
    <div class="file-tab">
      <div class="ch-file-bar">
        <Icon name="file" size={14} class="muted" />
        <span class="ch-path" title={path}>{name}</span>
        <span class="spacer" />
        <span class="muted-text small">Read-only</span>
      </div>
      {err && !got ? (
        <div class="ch-msg"><div>{err}</div><div class="muted-text small">{path}</div></div>
      ) : !got ? (
        <div class="ch-msg muted-text">Reading…</div>
      ) : (
        <Picture pic={{ url, mime: got.mime, size: got.size }} name={name} />
      )}
    </div>
  );
}
