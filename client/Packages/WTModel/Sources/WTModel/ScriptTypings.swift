import Foundation

// DATA-011: `wiretuner.d.ts` (scripting.adoc, "Typings"): the type definitions of the `wt` API
// that ship with the app, are copied to the Scripts folder on first launch and drive the Script
// Editor's completion.  Kept beside the bridge (`ScriptEnvironment`, `ScriptPrelude`) it describes;
// `ScriptTypingsTests` checks every member the prelude installs is declared here.

public enum ScriptTypings {
    /// The file name in the Scripts folder.
    public static let fileName = "wiretuner.d.ts"

    public static let declarations = """
    // wiretuner.d.ts -- the WireTuner scripting API (`wt`).  Every property set on a document
    // object is one labelled, undoable change; wrap many in wt.document.transaction.

    declare namespace wt {
      type Kind = "path" | "rectangle" | "ellipse" | "polygon" | "chart" | "connector" | "group" | "text" | "barcode" | "instance"
        | "placedFile" | "blend" | "extrude" | "image" | "layer" | "page" | "masterPage" | "swatch" | "style" | "script";

      interface Rect { x: number; y: number; width: number; height: number; }
      interface Point { x: number; y: number; }
      interface Size { width: number; height: number; }

      /** A page, layer or object.  Reading is free; setting a property makes one change. */
      interface WTObject {
        readonly id: string;
        readonly kind: Kind;
        name: string;
        notes: string;
        locked: boolean;
        /** Layers: shown or hidden.  Objects: read only. */
        visible: boolean;
        readonly bounds: Rect | null;
        position: Point | null;
        readonly size: Size | null;
        url: string;
        /** Text blocks: the whole text. */
        text?: string;
        /** Barcodes: the fixed content (ignored while bound to a field). */
        value?: string;
        /** Barcodes: "qr" or "code128". */
        symbology?: "qr" | "code128";
        layer: WTObject | null;
        readonly page: WTObject | null;
        /** Pages: the page number. */
        readonly number?: number;
        /** The data-merge binding, when bound. */
        readonly binding?: { field: string; kind: "image" | "visibility" | "link" | "text" } | null;
        /** Summaries only in version 1. */
        readonly fill?: string | null;
        readonly stroke?: string | null;
        /** Document scripts: the source and description. */
        source?: string;
        readonly description?: string;
        duplicate(): WTObject | null;
        remove(): void;
        moveTo(layer: WTObject | string): void;
        bringToFront(): void;
        sendToBack(): void;
      }

      interface Collection<T> extends Array<T> {
        /** Filters by any readable property: kind, name, layer or page (an object or its name). */
        where(filter: Partial<Record<keyof WTObject, unknown>>): Collection<T>;
      }

      interface Field { id: string; name: string; type: "text" | "number" | "date" | "boolean" | "image" | "link"; format: string; }
      interface DataSource { id: string; name: string; kind: "file" | "pasted" | "http" | "script" | "none"; url: string; connected: boolean; }

      interface Document {
        readonly name: string;
        readonly pages: Collection<WTObject>;
        readonly masterPages: Collection<WTObject>;
        readonly layers: Collection<WTObject>;
        readonly objects: Collection<WTObject>;
        readonly swatches: Collection<WTObject>;
        readonly styles: Collection<WTObject>;
        readonly scripts: Collection<WTObject>;
        readonly fields: Field[];
        readonly dataSources: DataSource[];
        selection: WTObject[];
        addField(name: string, type?: Field["type"]): string | null;
        /** Groups the sets made inside fn into one undo step labelled "Script: <label>". */
        transaction<T>(label: string, fn: () => T): T;
        createRectangle(options?: { x?: number; y?: number; width?: number; height?: number; layer?: string }): WTObject;
        createEllipse(options?: { x?: number; y?: number; width?: number; height?: number; layer?: string }): WTObject;
        createLine(options?: { x1?: number; y1?: number; x2?: number; y2?: number }): WTObject;
        createText(options?: { x?: number; y?: number; text?: string; layer?: string }): WTObject;
        createBarcode(options?: { x?: number; y?: number; value?: string; kind?: "qr" | "code128"; layer?: string }): WTObject;
        /** Not available in version 1. */
        placeImage(data: unknown, options?: object): WTObject;
        /** Exports the document through File > Export's pipeline with the format's default options:
         *  to `to` (a writer from `wt.ui.saveFile`), else to the file chosen in a save panel.
         *  True when written, false when the panel is cancelled. */
        export(options?: { format?: string; to?: { write(text: string): void }; fileName?: string }): boolean;
        /** Prints with the named print preset (the Print dialog's own), else the document's settings. */
        print(preset?: string): boolean;
      }

      interface Response {
        readonly status: number;
        readonly ok: boolean;
        readonly headers: Record<string, string>;
        text(): Promise<string>;
        json(): Promise<any>;
      }

      interface FetchOptions {
        method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
        headers?: Record<string, string>;
        body?: string;
        /** The name of a credential stored in the WireTuner cloud for the team or account. */
        credential?: string;
        /** Seconds, at most 120. */
        timeout?: number;
      }

      interface Progress { update(fraction: number, text?: string): void; done(): void; }

      const document: Document;
      const documents: Document[];
      /** A web request made by the WireTuner cloud on your behalf (permitted hosts only). */
      function fetch(url: string, options?: FetchOptions): Promise<Response>;
      const ui: {
        alert(message: string): void;
        confirm(message: string): boolean;
        prompt(message: string, defaultText?: string): string | null;
        choose(message: string, choices: string[]): string | null;
        openFile(options?: { types?: string[] }): string | null;
        saveFile(options?: { suggestedName?: string }): { write(text: string): void } | null;
        progress(title: string): Progress;
      };
      const records: {
        all(): Record<string, string>[];
        current(): Record<string, string> | null;
        readonly fields: Field[];
        merge(options: { to: "pages" | "pdf" | "printer"; [key: string]: unknown }): unknown;
      };
    }

    declare function setTimeout(fn: (...args: any[]) => void, milliseconds?: number, ...args: any[]): number;
    declare function clearTimeout(id: number): void;
    declare const console: { log(...a: any[]): void; warn(...a: any[]): void; error(...a: any[]): void; table(rows: any): void; };
    """
}
