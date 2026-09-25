#!/bin/bash
# Checks that every text of the apps has a Japanese translation (issue #34).
#
# The texts come from the compiler, not from a search of the sources: SecChainUI and SecChainCore are
# built in the Release configuration for macOS and for the iOS Simulator with
# `-emit-localized-strings`, which lists every string literal the code localizes, with the exact key
# (`%@`, `%lld`, ...) of each interpolation. Release leaves out the `#if DEBUG` controls, whose texts
# stay English, and the two platforms together cover every `#if os(...)` branch.
#
# Fails when
# - a localized string of the code is not in the String Catalog of SecChainUI,
# - a string of SecChainUI is not looked up with `bundle: .module`, or one of SecChainCore names no
#   bundle: SwiftUI and Foundation look in the app's main bundle by default, which has no
#   translations,
# - a key of a catalog has no Japanese translation, or one whose placeholders differ from English,
# - a key of the SecChainUI catalog is no longer used by the code.
#
# Usage: localization.sh
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIRECTORY="${REPOSITORY_ROOT}/tmp/localization"
CATALOG="${REPOSITORY_ROOT}/SecChainCore/Sources/SecChainUI/Resources/Localizable.xcstrings"
# Texts of the Info.plist files, such as the Face ID usage description.
INFO_PLIST_CATALOGS=("${REPOSITORY_ROOT}/SecChainiOS/InfoPlist.xcstrings")
LANGUAGE="ja"

# Placeholders of a text as a sorted list, without argument positions (`%1$@` is `%@`), so that a
# translation may reorder its arguments.
PLACEHOLDERS_JQ='def placeholders: [gsub("%%"; "") | scan("%(?:[0-9]+\\$)?(?:\\.[0-9]+)?(?:hh|h|ll|l|z)?[@dioxXufFeEgGaAcspn]") | sub("^%[0-9]+\\$"; "%")] | sort;'

# Starts from nothing: an incremental build that compiles nothing would emit no strings at all.
rm -rf "${WORK_DIRECTORY}"
mkdir -p "${WORK_DIRECTORY}"

# extract_strings <platform> [swift build options...]
extract_strings() {
  local platform="$1"
  shift
  echo "== extracting the localized strings for ${platform}"
  swift build \
    --package-path "${REPOSITORY_ROOT}/SecChainCore" \
    --scratch-path "${WORK_DIRECTORY}/build-${platform}" \
    --configuration release \
    --target SecChainUI \
    "$@" \
    -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "${WORK_DIRECTORY}/strings-${platform}"
}

extract_strings macos
# The deployment target is the one of Package.swift.
extract_strings ios --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"

# The native build system (the default up to Swift 6.3) writes the files to the path given above.
# Swift Build (the default from Swift 6.4, Xcode 27) ignores that path and leaves them among the
# intermediates of the scratch path. Each build system writes to only one of the two places.
STRINGS_FILES=()
while IFS= read -r -d '' strings_file; do
  STRINGS_FILES+=("${strings_file}")
done < <(find "${WORK_DIRECTORY}" -name '*.stringsdata' -print0)
if [ "${#STRINGS_FILES[@]}" -eq 0 ]; then
  echo "FAIL: the builds emitted no .stringsdata file under ${WORK_DIRECTORY}" >&2
  exit 1
fi

# One JSON object per localized string of the sources: table, source file, line, and key.
USAGES="${WORK_DIRECTORY}/usages.jsonl"
jq -c --arg sources "${REPOSITORY_ROOT}/SecChainCore/Sources/" '
  . as $file
  | select($file.source | startswith($sources))
  | .tables | to_entries[] | .key as $table
  | .value[] | {table: $table, source: $file.source, line: .location.startingLine, key: .key}
' "${STRINGS_FILES[@]}" > "${USAGES}"

FAILURES="${WORK_DIRECTORY}/failures.txt"
: > "${FAILURES}"

echo "== every localized string is looked up in the catalog"
while IFS=$'\t' read -r table source line key; do
  location="${source#"${REPOSITORY_ROOT}/"}:${line}"
  if [ "${table}" != "Localizable" ]; then
    echo "${location}: \"${key}\" uses the table ${table}, but the catalog is Localizable" >> "${FAILURES}"
    continue
  fi
  case "${source}" in
    */Sources/SecChainUI/*) required_bundle="bundle: .module" ;;
    *) required_bundle="bundle:" ;;
  esac
  if [[ "$(sed -n "${line}p" "${source}")" != *"${required_bundle}"* ]]; then
    echo "${location}: \"${key}\" is looked up in the main bundle, which has no translations; pass ${required_bundle} on the same line" >> "${FAILURES}"
  fi
done < <(jq -r '[.table, .source, .line, .key] | @tsv' "${USAGES}")

echo "== every string of the code has a ${LANGUAGE} translation in the catalog"
jq -r --slurpfile usages "${USAGES}" --arg language "${LANGUAGE}" "${PLACEHOLDERS_JQ}"'
  .sourceLanguage as $source_language
  | .strings as $strings
  | ($usages | map({(.key): true}) | add // {}) as $used
  | ($used | keys[] | select($strings[.] == null) | "Not in the catalog: \(.)"),
    ($strings | to_entries[] | select(.value.shouldTranslate != false)
      | .key as $key
      | (.value.localizations[$source_language].stringUnit.value // $key) as $source_text
      | .value.localizations[$language].stringUnit as $unit
      | (if ($unit.value // "") == "" or $unit.state != "translated" then "No \($language) translation: \($key)"
         elif ($unit.value | placeholders) != ($source_text | placeholders) then "Placeholders of the \($language) translation differ: \($key)"
         else empty end),
        (if $used[$key] then empty else "Not used by the code any more (remove it from the catalog): \($key)" end))
' "${CATALOG}" >> "${FAILURES}"

echo "== every Info.plist text has a ${LANGUAGE} translation"
for info_plist_catalog in "${INFO_PLIST_CATALOGS[@]}"; do
  jq -r --arg language "${LANGUAGE}" --arg catalog "${info_plist_catalog#"${REPOSITORY_ROOT}/"}" "${PLACEHOLDERS_JQ}"'
    .sourceLanguage as $source_language
    | .strings | to_entries[] | select(.value.shouldTranslate != false)
    | .key as $key
    | (.value.localizations[$source_language].stringUnit.value // $key) as $source_text
    | .value.localizations[$language].stringUnit as $unit
    | if ($unit.value // "") == "" or $unit.state != "translated" then "No \($language) translation in \($catalog): \($key)"
      elif ($unit.value | placeholders) != ($source_text | placeholders) then "Placeholders of the \($language) translation differ in \($catalog): \($key)"
      else empty end
  ' "${info_plist_catalog}" >> "${FAILURES}"
done

if [ -s "${FAILURES}" ]; then
  cat "${FAILURES}" >&2
  echo "FAIL: $(wc -l < "${FAILURES}" | tr -d ' ') problem(s) in the translations" >&2
  exit 1
fi
echo "PASS (localization): $(jq -s 'map(.key) | unique | length' "${USAGES}") strings"
