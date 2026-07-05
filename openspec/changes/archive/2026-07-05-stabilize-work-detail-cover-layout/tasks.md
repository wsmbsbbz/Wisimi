## 1. Implementation

- [x] 1.1 Update the work detail hero cover so its loading, failure, and loaded states all occupy the same 4:3 frame within the available page width.
- [x] 1.2 Preserve `scaledToFill` and clipping for the main cover without changing fixed-size `CoverImage` call sites.

## 2. Verification

- [x] 2.1 Verify the work detail page on at least one narrow and one large iPhone viewport/simulator size: cover space is stable before/after load, and content does not overflow horizontally.
- [x] 2.2 Run the smallest available build or compile check for the iOS target.
