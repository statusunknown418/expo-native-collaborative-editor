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

export type ListKind = 'ordered' | 'unordered' | 'checklist';

export type ListsOptions = {
  ordered?: boolean;
  unordered?: boolean;
  checklist?: boolean;
  /** Explicitly cascades a user toggle to checklist descendants; no automatic rollup. */
  caution__enableChecklistChildrenAutoCompletion?: boolean;
};

export type NativeCapabilities = {
  readonly formatting: {
    readonly version: number;
    readonly bold: boolean;
    readonly italic: boolean;
    readonly headingLevels: readonly HeadingLevel[];
  };
  readonly lists: {
    readonly version: number;
    readonly ordered: boolean;
    readonly unordered: boolean;
    readonly checklist: boolean;
  };
};

/** Explicit registration, with defaults normalized before crossing the native boundary. */
export function formattingPlugin(
  options: FormattingOptions = {}
): FeaturePlugin<Required<FormattingOptions>> {
  return {
    capability: 'formatting',
    id: 'formatting',
    options: {
      bold: options.bold ?? true,
      headingLevels: [...new Set<HeadingLevel>(options.headingLevels ?? [1, 2, 3, 4, 5, 6])].sort(),
      italic: options.italic ?? true,
    },
    version: 1,
  };
}

export function listsPlugin(options: ListsOptions = {}): FeaturePlugin<Required<ListsOptions>> {
  return {
    capability: 'lists',
    id: 'lists',
    options: {
      caution__enableChecklistChildrenAutoCompletion:
        options.caution__enableChecklistChildrenAutoCompletion ?? false,
      checklist: options.checklist ?? true,
      ordered: options.ordered ?? true,
      unordered: options.unordered ?? true,
    },
    version: 1,
  };
}
