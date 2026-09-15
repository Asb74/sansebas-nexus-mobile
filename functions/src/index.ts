import Busboy from "busboy";
import FormData from "form-data";
import {initializeApp} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {defineSecret} from "firebase-functions/params";
import {onRequest} from "firebase-functions/v2/https";
import {request as httpsRequest} from "node:https";

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
  constructor(
    readonly code: string,
    readonly status: number,
    readonly providerStatus?: number,
    readonly providerBody?: string,
  ) {
    super(code);
  }
}

const maxProviderDiagnosticCharacters = 1000;

function safeProviderDiagnostic(value: unknown): string {
  const message = typeof value === "string" ? value : String(value ?? "unknown");
  return message
    .replace(/bearer\s+[^\s,;]+/gi, "Bearer [REDACTED]")
    .replace(/authorization\s*[:=]\s*[^\s,;]+/gi, "Authorization=[REDACTED]")
    .replace(/\bsk-[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .replace(/\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .replace(/[\r\n\t]+/g, " ")
    .substring(0, maxProviderDiagnosticCharacters);
}

async function requestTranscription(upload: AudioUpload): Promise<string> {
  const model = "gpt-4o-mini-transcribe";
  const form = new FormData();
  form.append("file", upload.bytes, {
    filename: upload.filename,
    contentType: upload.mimeType,
  });
  form.append("model", model);
  console.log(
    `TRANSCRIPTION_PROVIDER_REQUEST provider=openai model=${model} ` +
    `filename=${upload.filename} mime=${upload.mimeType} size_bytes=${upload.bytes.length}`,
  );
  let providerResponse: {status: number; contentType?: string; body: string};
  try {
    const contentLength = await new Promise<number>((resolve, reject) => {
      form.getLength((caught, length) => caught ? reject(caught) : resolve(length));
    });
    providerResponse = await new Promise((resolve, reject) => {
      const providerRequest = httpsRequest({
        protocol: "https:",
        hostname: "api.openai.com",
        path: "/v1/audio/transcriptions",
        method: "POST",
        headers: {
          ...form.getHeaders(),
          Authorization: `Bearer ${openAiApiKey.value()}`,
          "Content-Length": contentLength,
        },
      }, (response) => {
        const chunks: Buffer[] = [];
        response.on("error", reject);
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () => resolve({
          status: response.statusCode ?? 502,
          contentType: response.headers["content-type"],
          body: Buffer.concat(chunks).toString("utf8"),
        }));
      });
      providerRequest.on("error", reject);
      form.on("error", reject);
      form.pipe(providerRequest);
    });
  } catch (caught) {
    const name = safeProviderDiagnostic(caught instanceof Error ? caught.name : "unknown");
    const message = safeProviderDiagnostic(caught instanceof Error ? caught.message : caught);
    const cause = safeProviderDiagnostic(caught instanceof Error ? caught.cause : undefined);
    console.error(
      `TRANSCRIPTION_PROVIDER_ERROR provider=openai name=${JSON.stringify(name)} ` +
      `message=${JSON.stringify(message)} cause=${JSON.stringify(cause)}`,
    );
    throw new UploadError("transcription_provider_fetch_error", 502, undefined, message);
  }
  const providerOk = providerResponse.status >= 200 && providerResponse.status < 300;
  console.log(
    `TRANSCRIPTION_PROVIDER_RESPONSE provider=openai status=${providerResponse.status} ok=${providerOk}`,
  );
  const responseBody = providerResponse.body;
  const safeResponseBody = safeProviderDiagnostic(responseBody);
  if (!providerOk) {
    console.error(
      `TRANSCRIPTION_PROVIDER_ERROR provider=openai status=${providerResponse.status} ` +
      `content_type=${providerResponse.contentType ?? "unknown"} body=${JSON.stringify(safeResponseBody)}`,
    );
    throw new UploadError(
      "transcription_provider_error",
      502,
      providerResponse.status,
      safeResponseBody,
    );
  }
  let body: {text?: unknown} | undefined;
  try {
    body = JSON.parse(responseBody) as {text?: unknown};
  } catch {
    body = undefined;
  }
  const text = typeof body?.text === "string" ? body.text.trim() : "";
  if (!text) {
    console.error(
      `TRANSCRIPTION_PROVIDER_INVALID_RESPONSE status=${providerResponse.status} ` +
      `body=${JSON.stringify(safeResponseBody)}`,
    );
    throw new UploadError(
      "transcription_provider_error",
      502,
      providerResponse.status,
      safeResponseBody,
    );
  }
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
        if (caught.code === "transcription_provider_error") {
          response.status(caught.status).json({
            error: caught.code,
            provider_status: caught.providerStatus,
            provider_message: caught.providerBody,
          });
          return;
        }
        if (caught.code === "transcription_provider_fetch_error") {
          response.status(caught.status).json({
            error: caught.code,
            provider_message: caught.providerBody,
          });
          return;
        }
        error(response, caught.status, caught.code);
        return;
      }
      console.error("Transcription request failed", caught instanceof Error ? caught.name : "unknown");
      error(response, 500, "transcription_internal_error");
    }
  },
);
