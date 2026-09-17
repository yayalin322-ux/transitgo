// A minimal in-memory fake of the S3Client surface graphStorage.mjs actually uses
// (send() with Put/Get/Head/List/DeleteObjectCommand) — real @aws-sdk/client-s3 classes
// are still used as the command objects (so instanceof checks work identically to
// production), only the network transport is faked. No test in this repo depends on a
// real Supabase Storage bucket being reachable.
import {
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";
import { Readable } from "node:stream";

export class FakeS3Client {
  constructor() {
    /** @type {Map<string, Buffer>} */
    this.objects = new Map();
    this.failNextPut = null; // set to an Error to make the next PutObjectCommand throw
    this.failNextGet = null;
  }

  async send(command) {
    if (command instanceof PutObjectCommand) {
      if (this.failNextPut) {
        const e = this.failNextPut;
        this.failNextPut = null;
        throw e;
      }
      const body = await bodyToBuffer(command.input.Body);
      this.objects.set(command.input.Key, body);
      return {};
    }

    if (command instanceof GetObjectCommand) {
      if (this.failNextGet) {
        const e = this.failNextGet;
        this.failNextGet = null;
        throw e;
      }
      const body = this.objects.get(command.input.Key);
      if (!body) {
        const e = new Error("NoSuchKey");
        e.name = "NoSuchKey";
        e.$metadata = { httpStatusCode: 404 };
        throw e;
      }
      return { Body: Readable.from([body]) };
    }

    if (command instanceof HeadObjectCommand) {
      const body = this.objects.get(command.input.Key);
      if (!body) {
        const e = new Error("NotFound");
        e.$metadata = { httpStatusCode: 404 };
        throw e;
      }
      return { ContentLength: body.length };
    }

    if (command instanceof ListObjectsV2Command) {
      const keys = [...this.objects.keys()].filter((k) => k.startsWith(command.input.Prefix));
      return { Contents: keys.map((Key) => ({ Key })), IsTruncated: false };
    }

    if (command instanceof DeleteObjectCommand) {
      this.objects.delete(command.input.Key);
      return {};
    }

    throw new Error(`FakeS3Client: unhandled command ${command.constructor.name}`);
  }
}

async function bodyToBuffer(body) {
  if (Buffer.isBuffer(body)) return body;
  if (typeof body === "string") return Buffer.from(body);
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}
