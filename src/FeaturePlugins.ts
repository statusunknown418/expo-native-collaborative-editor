/** Provisional native feature-plugin contract. New native behavior requires a rebuild. */
export type FeaturePlugin<Options extends object = object> = {
  readonly id: string;
  readonly capability: string;
  readonly version: number;
  readonly options: Options;
};

export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;

export type FormattingOptions = {
  /** Enables bold authoring; existing marks remain visible when disabled. */
  bold?: boolean;
  italic?: boolean;
  headingLevels?: readonly HeadingLevel[];
};

export type NativeCapabilities = {
  readonly formatting: {
    readonly version: number;
    readonly bold: boolean;
    readonly italic: boolean;
    readonly headingLevels: readonly HeadingLevel[];
  };
};

/** Explicit registration, with defaults normalized before crossing the native boundary. */
export function formattingPlugin(
  options: FormattingOptions = {}
): FeaturePlugin<Required<FormattingOptions>> {
  return {
    id: 'formatting',
    capability: 'formatting',
    version: 1,
    options: {
      bold: options.bold ?? true,
      italic: options.italic ?? true,
      headingLevels: [...new Set<HeadingLevel>(options.headingLevels ?? [1, 2, 3, 4, 5, 6])].sort(),
    },
  };
}
