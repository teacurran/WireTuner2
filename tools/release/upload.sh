#!/usr/bin/env bash
# `make release-upload [UPLOAD=1]`: publishes a release to the R2 bucket behind
# updates.villagecompute.com (docs/spec/releasing.adoc, "Publishing"; D-080).
#
#     tools/release/upload.sh            # dry run: checks everything, prints each command, sends nothing
#     tools/release/upload.sh --upload   # uploads
#
# Keys, under wiretuner/<channel>/ (the channel is the app's SUFeedURL's folder):
#     WireTuner-<name>.zip           the zip (Sparkle's enclosure with WT_APPCAST_ENCLOSURE=r2)
#     WireTuner-<name>.dmg           the DMG
#     WireTuner-<name>.sha256        SHA256SUMS.txt
#     WireTuner-<channel>.dmg        a copy of the DMG at a fixed name, for a web page's link
#     appcast.xml                    last, so the feed never names a file not yet there
# When the appcast's enclosure is the GitHub release asset (the default, D-080), a real upload first
# checks the asset answers, so run `make release-publish PUBLISH=1` before this.
#
# R2 through the S3 API (aws CLI v2):
#     WT_R2_BUCKET        the bucket
#     WT_R2_ENDPOINT      https://<account id>.r2.cloudflarestorage.com, or WT_R2_ACCOUNT_ID
#     WT_R2_PROFILE       an aws CLI profile holding the R2 token's key pair, or the usual
#                         AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the environment
# A real upload refuses anything not publishable: a build that is not Developer ID signed and
# notarized, or an appcast whose items are not all EdDSA-signed.
source "$(dirname "$0")/common.sh"

upload=false
case "${1:-}" in
--upload) upload=true ;;
"" | --dry-run) ;;
*) die "usage: $0 [--upload]" ;;
esac

dir="$(release_dir)"
manifest="$dir/release.json"
[ -f "$manifest" ] || die "no $manifest: run make release first"
field() { plutil -extract "$1" raw -o - "$manifest"; }
name="$(field name)"
version="$(field version)" build="$(field build)" notarized="$(field notarized)" signing="$(field signing)"
feed="$(field feed)"
dist="$dir/dist"
dmg="$dist/$(field dmg)"
zip="$dist/$(field zip)"
appcast="$dist/appcast.xml"
for file in "$dmg" "$zip" "$appcast" "$dist/SHA256SUMS.txt"; do [ -f "$file" ] || die "missing $file"; done
(cd "$dist" && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || die "the files do not match SHA256SUMS.txt"

problems=()
[ "$signing" = developer-id ] || problems+=("the build is not Developer ID signed ($signing)")
[ "$notarized" = true ] || problems+=("the build is not notarized")
grep -q 'UNSIGNED TEST APPCAST' "$appcast" && problems+=("the appcast is an unsigned test appcast")
items="$(grep -c '<enclosure ' "$appcast" || true)"
signed_items="$(grep -c '<enclosure [^>]*sparkle:edSignature=' "$appcast" || true)"
[ "$items" -gt 0 ] && [ "$items" = "$signed_items" ] || problems+=("$((items - signed_items)) of $items appcast items lack an EdDSA signature")
grep -q "<sparkle:version>$build</sparkle:version>" "$appcast" || problems+=("the appcast has no item for build $build")

case "$feed" in https://*/appcast.xml) ;; *) die "release.json feed '$feed' is not an https appcast" ;; esac
base_url="${feed%/appcast.xml}"
channel="${base_url##*/}"
prefix="${WT_R2_PREFIX:-wiretuner/$channel}"
bucket="${WT_R2_BUCKET:-}"
endpoint="${WT_R2_ENDPOINT:-${WT_R2_ACCOUNT_ID:+https://$WT_R2_ACCOUNT_ID.r2.cloudflarestorage.com}}"

if [ "$upload" = true ]; then
    if [ ${#problems[@]} -gt 0 ]; then
        printf '  - %s\n' "${problems[@]}" >&2
        die "refusing to publish $version ($build)"
    fi
    [ -n "$bucket" ] || die "WT_R2_BUCKET is not set"
    [ -n "$endpoint" ] || die "WT_R2_ENDPOINT (or WT_R2_ACCOUNT_ID) is not set"
    command -v aws >/dev/null || die "the aws CLI is not installed (brew install awscli)"
    enclosure="$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' "$appcast" | head -n 1)"
    case "$enclosure" in
    https://github.com/*)
        code="$(curl -sS -o /dev/null -I -L -w '%{http_code}' --max-time 30 "$enclosure" || true)"
        [ "$code" = 200 ] || die "the appcast's enclosure $enclosure answers HTTP ${code:-none}: publish the GitHub release first (make release-publish PUBLISH=1)"
        ;;
    esac
else
    bucket="${bucket:-<WT_R2_BUCKET>}"
    endpoint="${endpoint:-<WT_R2_ENDPOINT>}"
fi

aws_base=(aws s3 cp --endpoint-url "$endpoint" --only-show-errors)
if [ -n "${WT_R2_PROFILE:-}" ]; then aws_base+=(--profile "$WT_R2_PROFILE"); fi
# R2 speaks S3 with region "auto" and does not take the CLI's newer default checksum headers.
export AWS_DEFAULT_REGION=auto AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

step() { # step FILE KEY CONTENT-TYPE CACHE-CONTROL
    local command=("${aws_base[@]}" "$1" "s3://$bucket/$prefix/$2" --content-type "$3" --cache-control "$4")
    if [ "$upload" = true ]; then
        say "upload $2"
        "${command[@]}"
    else
        printf ' '
        printf ' %q' "${command[@]}"
        printf '\n'
    fi
}

stem="WireTuner-$name"
immutable="public, max-age=31536000, immutable"
if [ "$upload" = true ]; then
    say "publishing $version ($build) to s3://$bucket/$prefix ($base_url)"
else
    say "dry run (make release-upload UPLOAD=1 uploads): $name, $version ($build) -> s3://$bucket/$prefix"
    if [ ${#problems[@]} -gt 0 ]; then
        warn "a real upload would refuse this release:"
        printf '  - %s\n' "${problems[@]}" >&2
    fi
fi
step "$zip" "$stem.zip" application/zip "$immutable"
step "$dmg" "$stem.dmg" application/x-apple-diskimage "$immutable"
step "$dist/SHA256SUMS.txt" "$stem.sha256" "text/plain; charset=utf-8" "$immutable"
step "$dmg" "WireTuner-$channel.dmg" application/x-apple-diskimage "public, max-age=300"
step "$appcast" appcast.xml "application/xml; charset=utf-8" "public, max-age=300"

if [ "$upload" = true ]; then
    # The public side, as Sparkle will see it.
    for key in appcast.xml "$stem.zip"; do
        code="$(curl -sS -o /dev/null -I -w '%{http_code}' --max-time 30 "$base_url/$key" || true)"
        [ "$code" = 200 ] && say "public: $base_url/$key" || warn "$base_url/$key answers HTTP ${code:-none} (the bucket's public domain?)"
    done
    say "published $name to R2"
fi
