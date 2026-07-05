## Context

`DetailHero` currently renders the main work cover through `CoverImage(url:cornerRadius:)` and then applies `.aspectRatio(4 / 3, contentMode: .fit)`. Because `CoverImage` has no fixed height when `size == nil`, its loading state is small, while the loaded image can participate in layout with a much larger intrinsic size. This causes the track directory to jump downward and can let oversized covers expand the page.

asmr.one work covers are guaranteed to be 4:3, so the detail page does not need dynamic image-ratio measurement.

## Goals / Non-Goals

**Goals:**
- Reserve a stable 4:3 space for the detail page main cover before the remote image finishes loading.
- Keep the cover within the screen's available content width on all supported iOS device sizes.
- Continue using `scaledToFill` with clipping for the main cover.

**Non-Goals:**
- Do not change work list cards, player artwork, mini-player artwork, or track image preview sheets.
- Do not add image-dimension probing, caching, or a new image loading dependency.
- Do not support historical non-4:3 cover formats.

## Decisions

- Put the 4:3 constraint on the cover's actual frame instead of relying on image intrinsic size.
  - Rationale: this fixes both loading-state jump and oversized-image overflow with one layout rule.
  - Alternative considered: wait for the image and calculate its aspect ratio. Rejected because source covers are already guaranteed 4:3.

- Keep `scaledToFill` and `.clipped()` for the main cover.
  - Rationale: this matches the existing visual intent and avoids letterboxing. With a 4:3 source in a 4:3 container, clipping should be a no-op for normal covers.
  - Alternative considered: `scaledToFit`. Rejected because it can introduce blank space and is unnecessary for guaranteed 4:3 covers.

- Scope the change to the detail hero use case.
  - Rationale: `CoverImage` is also used by fixed-size player UI, which already has explicit dimensions and should not be affected.
  - Alternative considered: globally changing `CoverImage` when `size == nil`. Acceptable only if implemented as the smallest equivalent fix and verified not to affect other call sites.

## Risks / Trade-offs

- Source cover assumption changes → if asmr.one later serves non-4:3 covers, the detail page will crop them; revisit the layout only after that becomes real.
- SwiftUI modifier ordering mistake → the cover may still use intrinsic image size; verify by checking loading and loaded states on narrow and large iPhone sizes.
