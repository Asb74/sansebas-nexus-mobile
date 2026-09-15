import Busboy from "busboy";
import {initializeApp} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {defineSecret} from "firebase-functions/params";
import {onRequest} from "firebase-functions/v2/https";

initializeApp();

const openAiApiKey = defineSecret("OPENAI_API_KEY");
const maxAudioBytes = 20 * 1024 * 1024;
const supportedExtensions = new Set(["m4a", "mp4", "wav", "mp3"]);

type AudioUpload = {
  bytes: Buffer;
  filename: string;
  mimeType: string;
};

function error(response: {status: (code: number) => unknown; json: (body: object) => unknown}, status: number, code: string) {
  response.status(status);
  response.json({error: code});
}

async function readAudio(request: {headers: Record<string, string | string[] | undefined>; rawBody?: Buffer}): Promise<AudioUpload> {
  const contentType = request.headers["content-type"];
  if (typeof contentType !== "string" || !contentType.toLowerCase().startsWith("multipart/form-data")) {
    throw new UploadError("invalid_file", 400);
  }

  return new Promise((resolve, reject) => {
    let upload: AudioUpload | undefined;
    let tooLarge = false;
    const parser = Busboy({headers: request.headers, limits: {files: 1, fileSize: maxAudioBytes}});
    parser.on("file", (fieldName, stream, info) => {
      const chunks: Buffer[] = [];
      if (fieldName !== "file") stream.resume();
      stream.on("limit", () => { tooLarge = true; });
      stream.on("data", (chunk: Buffer) => chunks.push(chunk));
      stream.on("end", () => {
        if (fieldName === "file") {
          upload = {bytes: Buffer.concat(chunks), filename: info.filename, mimeType: info.mimeType};
        }
      });
    });
    parser.on("error", () => reject(new UploadError("invalid_file", 400)));
    parser.on("finish", () => {
      if (tooLarge) return reject(new UploadError("file_too_large", 413));
      if (!upload || upload.bytes.length === 0) return reject(new UploadError("invalid_file", 400));
      const extension = upload.filename.split(".").pop()?.toLowerCase() ?? "";
      if (!supportedExtensions.has(extension)) return reject(new UploadError("invalid_file", 400));
      resolve(upload);
    });
    parser.end(request.rawBody ?? Buffer.alloc(0));
  });
}

class UploadError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

async function requestTranscription(upload: AudioUpload): Promise<string> {
  const model = "gpt-4o-mini-transcribe";
  const form = new FormData();
  const fileBytes = new Uint8Array(upload.bytes);
  form.append("file", new Blob([fileBytes], {type: upload.mimeType}), upload.filename);
  form.append("model", model);
  console.log(
    `TRANSCRIPTION_PROVIDER_REQUEST provider=openai model=${model} ` +
    `filename=${upload.filename} mime=${upload.mimeType} size_bytes=${upload.bytes.length}`,
  );
  const providerResponse = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: {Authorization: `Bearer ${openAiApiKey.value()}`},
    body: form,
  });
  const providerContentType = providerResponse.headers.get("content-type");
  console.log(
    `TRANSCRIPTION_PROVIDER_RESPONSE provider=openai status=${providerResponse.status} ok=${providerResponse.ok}`,
  );
  if (!providerResponse.ok) {
    const errorBody = await providerResponse.text();
    console.error(
      `TRANSCRIPTION_PROVIDER_ERROR provider=openai status=${providerResponse.status} ` +
      `content_type=${providerContentType ?? "unknown"} body=${errorBody.substring(0, 2000)}`,
    );
    throw new UploadError("transcription_provider_error", 502);
  }
  const body = await providerResponse.json() as {text?: unknown};
  const text = typeof body.text === "string" ? body.text.trim() : "";
  if (!text) throw new UploadError("transcription_provider_error", 502);
  return text;
}

export const transcribe = onRequest(
  {region: "europe-west1", secrets: [openAiApiKey], timeoutSeconds: 120, memory: "512MiB"},
  async (request, response) => {
    if (request.method !== "POST") {
      response.set("Allow", "POST");
      error(response, 405, "method_not_allowed");
      return;
    }

    const authorization = request.header("authorization") ?? "";
    const match = authorization.match(/^Bearer\s+(.+)$/i);
    if (!match) {
      error(response, 401, "unauthorized");
      return;
    }
    try {
      await getAuth().verifyIdToken(match[1]);
    } catch {
      error(response, 401, "unauthorized");
      return;
    }

    try {
      const upload = await readAudio(request);
      const text = await requestTranscription(upload);
      response.status(200).json({text});
    } catch (caught) {
      if (caught instanceof UploadError) {
        error(response, caught.status, caught.code);
        return;
      }
      console.error("Transcription request failed", caught instanceof Error ? caught.name : "unknown");
      error(response, 500, "transcription_internal_error");
    }
  },
);
