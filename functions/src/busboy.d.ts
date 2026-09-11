declare module "busboy" {
  import {Writable} from "node:stream";

  type Headers = Record<string, string | string[] | undefined>;
  type FileInfo = {filename: string; encoding: string; mimeType: string};
  type FileStream = NodeJS.ReadableStream & {resume(): void};
  type Parser = Writable & {
    on(event: "file", listener: (name: string, stream: FileStream, info: FileInfo) => void): Parser;
    on(event: "error", listener: (error: Error) => void): Parser;
    on(event: "finish", listener: () => void): Parser;
  };

  export default function busboy(configuration: {
    headers: Headers;
    limits?: {files?: number; fileSize?: number};
  }): Parser;
}
