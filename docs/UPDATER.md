# Signed in-app updates

Claude Dash uses [Sparkle 2](https://sparkle-project.org/) for signed in-app
updates when a release has both an Ed25519 public key and an HTTPS appcast. The
app uses Sparkle's standard UI: **Check for Updates…** downloads a verified
release and offers **Install and Relaunch**.

Release builds check the signed feed automatically, but do not silently install
anything: `SUEnableAutomaticChecks=true` and `SUAllowsAutomaticUpdates=false`
leave the final install/relaunch decision with the user.

This is deliberately a layered rollout:

- A source build, old release, or build without `SUPublicEDKey` keeps the
  existing GitHub Releases checker. It can still be upgraded with
  `git pull && ./install.sh` or a release zip.
- The first Sparkle-enabled release must still be installed manually. Only a
  running build that contains the public key can trust and install a later
  signed update.
- No user needs an Apple Developer Program membership for source builds or
  in-app update verification. A future Developer ID/notarized distribution is
  still worthwhile for macOS Gatekeeper's first-download experience; it is
  separate from Sparkle's Ed25519 archive/feed verification.

## What is pinned

`Scripts/bootstrap-sparkle.sh` downloads the official universal
`Sparkle-2.9.4.tar.xz`, verifies this SHA-256 before extracting it, and places
the framework plus `generate_appcast` tools under ignored `Vendor/Sparkle/`:

```text
ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9
```

The non-Xcode build embeds `Sparkle.framework`, links it via
`@executable_path/../Frameworks`, and signs the framework's XPC services,
Autoupdate helper, Updater app, framework, then outer app in that order.
The complete Sparkle license/third-party notice file is copied into the app's
Resources and verified byte-for-byte before packaging.

## One-time release-owner setup

Do these only when ready to enable the first signed release. Do not run them
as part of ordinary development, and do not put a private key in a shell
command, repository, app bundle, issue, or chat.

1. Bootstrap the pinned Sparkle distribution and create one app-specific key
   in the release owner's login Keychain:

   ```bash
   ./Scripts/bootstrap-sparkle.sh
   ./Vendor/Sparkle/bin/generate_keys --account com.claudedash.app
   ```

   Sparkle prints a `SUPublicEDKey` value. Keep the private key in the login
   Keychain; this command does not need to be rerun for later releases.

2. Save the public value for local release-candidate builds without committing
   it (the file is intentionally ignored):

   ```bash
   mkdir -p Config
   printf '%s\n' 'PASTE_THE_PUBLIC_SUPublicEDKey_VALUE' > Config/SparklePublicKey.txt
   ```

3. Create the protected Actions environment and store the public and private
   values. The public key is a repository variable; the private key is an
   environment secret. `gh secret set` encrypts the value locally before it is
   sent to GitHub.

   ```bash
   gh api --method PUT repos/brianyoungilcho/claude-dash/environments/sparkle-release
   gh variable set SPARKLE_PUBLIC_ED_KEY --repo brianyoungilcho/claude-dash \
     --body 'PASTE_THE_PUBLIC_SUPublicEDKey_VALUE'

   key_dir="$(mktemp -d -t claude-dash-sparkle-key)"
   chmod 700 "$key_dir"
   key_file="$key_dir/private-key"
   ./Vendor/Sparkle/bin/generate_keys --account com.claudedash.app -x "$key_file"
   chmod 600 "$key_file"
   gh secret set SPARKLE_PRIVATE_ED_KEY --repo brianyoungilcho/claude-dash \
     --env sparkle-release < "$key_file"
   rm -rf "$key_dir"
   ```

   Keep an encrypted offline backup of the private key before removing any
   export file. On APFS/SSD storage, deletion is not a secure-erasure claim.
   Protect the `sparkle-release` environment with required reviewers in
   GitHub if releases need an approval gate.

4. In GitHub, open **Settings → Pages → Build and deployment** and select
   **GitHub Actions** as the source. The release workflow publishes the signed
   `appcast.xml` to:

   ```text
   https://brianyoungilcho.github.io/claude-dash/appcast.xml
   ```

   Release candidates use the isolated
   `https://brianyoungilcho.github.io/claude-dash/appcast-rc.xml` feed. A Pages
   deployment preserves both files, so an RC can never replace or advertise on
   the production channel. Custom deployments may set `SPARKLE_RC_FEED_URL` in
   addition to `SPARKLE_FEED_URL`; each URL must map to the corresponding file
   in the same Pages deployment.

   For a custom HTTPS domain served by that same GitHub Pages deployment, set
   `SPARKLE_FEED_URL` as a repository Actions variable before release. It must
   match the URL embedded in the built app.

5. Confirm a configured local candidate before tagging anything:

   ```bash
   CLAUDE_DASH_REQUIRE_SPARKLE=1 \
   CLAUDE_DASH_APP_PATH=/tmp/Claude-Dash-rc.app \
   ./build.sh
   CLAUDE_DASH_REQUIRE_SPARKLE=1 \
   ./Scripts/verify-sparkle-bundle.sh /tmp/Claude-Dash-rc.app
   ```

   This proves the universal bundle, embedded framework, `@rpath`, nested
   signatures, public key, signed-feed requirement, and HTTPS feed setting.

## Release behavior

Pushing a valid `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-rc.N` tag performs
this order (all release tags share one concurrency lock so feed updates cannot
race):

1. Bootstrap Sparkle, run the headless tests, build a universal candidate, and
   verify its bundle/signature invariants.
2. In the protected `sparkle-release` environment, rebuild and make a zip.
3. Verify the configured public/private key pair, then pipe the private key to
   `generate_appcast` on stdin. It signs the zip entry and appcast; the workflow
   does not put the key in an argument or file.
4. Create a **draft** GitHub release, attach the archive, then publish it so the
   download exists before any client can discover the update.
5. Deploy the signed appcast through GitHub Pages. If Pages fails, the release
   remains available through the existing manual update path without advertising
   a broken in-app download. The Homebrew cask is updated as before.

RC tags are published as GitHub prereleases, are never marked Latest, never
bump Homebrew, and use `appcast-rc.xml`. Their numeric `CFBundleVersion` values
increase from RC1 to RC2 while remaining below the final production build.
Production tags use `appcast.xml` and reserve the higher final build number.
Each successive RC and production tag must point to a distinct commit. GitHub
Pages identifies a deployment by the source commit OID; reusing one commit for
two tags can report a successful second deployment while retaining the first
artifact. A release-notes-only commit is sufficient when the app source itself
does not change between candidates.

If neither Sparkle key has been configured, releases keep working but build in
manual GitHub-release fallback mode. If only one key is configured, the
workflow fails rather than accidentally publishing a half-configured updater.

The workflow preserves up to three existing appcast entries and deliberately
does not create binary deltas (`--maximum-deltas 0`): GitHub Releases remain
the immutable archive store while Pages hosts only the small signed feed.

## Homebrew boundary

This repository does not change the separate `homebrew-tap` cask. Keep the
cask's normal upgrade behavior until a real Homebrew install has passed the
RC1 → RC2 test below. After that proof, the tap owner can add
`auto_updates true` to `Casks/claude-dash.rb` so Homebrew understands that the
embedded updater owns this app bundle. Do not set it earlier: a broken first
in-app update would otherwise leave Homebrew users without an ordinary repair
path.

## Before public rollout

Exercise a real two-build RC upgrade after the keys and Pages site exist:

1. Tag and push `v1.6.0-rc.1`. After the workflow succeeds, install its release
   archive manually into `/Applications` and launch it. It uses build `1060001`
   and the isolated RC feed.
2. Tag and push `v1.6.0-rc.2`. It uses higher build `1060002`; the final
   `v1.6.0` build is `1060099`, so Sparkle ordering remains monotonic.
3. On RC1 choose **Check for Updates… → Install and Relaunch**.
4. Verify the app relaunches as RC2 and preserves Keychain keys, account
   metadata, notes, preferences, login-at-startup state, and board frame.
5. Repeat on both Apple Silicon and Intel, and test a deliberately invalid
   appcast/archive signature to make sure Sparkle refuses it.

Do not publish the first production Sparkle-enabled tag until that end-to-end
RC path has passed.
