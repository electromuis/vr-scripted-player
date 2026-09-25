# gde_gozen patches

Every `*.patch` here is applied (`git apply`, in name order) on top of the
gde_gozen source that `.github/workflows/build.yml` builds (`GOZEN_REPO` @
`GOZEN_REF`). Changing a patch invalidates the cached gde_gozen builds.

Two ways to ship our own gde_gozen changes (the audio loading fix):

- **Fork:** fork https://github.com/VoylinsGamedevJourney/gde_gozen, push the
  fix, and set `GOZEN_REPO` / `GOZEN_REF` in the workflow to the fork and its
  branch or commit.
- **Patch:** in a gde_gozen checkout at `GOZEN_REF`, commit the fix and run
  `git format-patch -1 -o <this folder>`.
