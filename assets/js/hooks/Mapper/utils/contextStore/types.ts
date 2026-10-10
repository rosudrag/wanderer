export type AnyProperty<T> = T[keyof T];

export type PCDHandleBeforeUpdate<T> = (
  newVal: AnyProperty<T>,
  prev: AnyProperty<T>,
) => {
  value: AnyProperty<T>;
  prevent?: boolean;
} | void;

export type UpdateFunc<T> = (props: T) => Partial<T>;
export type ContextStoreDataUpdate<T> = (values: Partial<T> | UpdateFunc<T>, force?: boolean) => void;

export type ContextStoreDataOpts<T> = {
  notNeedRerender?: boolean;
  handleBeforeUpdate?: PCDHandleBeforeUpdate<T>;
  onAfterAUpdate?: (values: Partial<T>) => void;
};

export type ContextStoreListener = () => void;
export type ContextStoreUnsubscribe = () => void;

export type ProvideConstateDataReturnType<T> = {
  update: ContextStoreDataUpdate<T>;
  ref: T;
  /**
   * Subscribes to changes on exactly the listed KEYS (not "any change anywhere" - see
   * `useMapSelector`, which discovers which keys a selector actually reads and subscribes to
   * only those). Returns an unsubscribe function. A listener is notified at most once per
   * animation frame even if multiple of its subscribed keys changed in the same frame (see
   * `useContextStore`'s whole-queue drain).
   */
  subscribe: (keys: (keyof T)[], listener: ContextStoreListener) => ContextStoreUnsubscribe;
};
