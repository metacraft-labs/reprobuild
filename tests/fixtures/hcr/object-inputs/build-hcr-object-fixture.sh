#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <output-dir>" >&2
  exit 2
fi

out_dir="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cc_bin="${CC:-cc}"

mkdir -p "${out_dir}"

common_flags=(
  -c
  -g
  -O0
  -ffunction-sections
  -fpatchable-function-entry=8,4
)

old_obj="${out_dir}/hcr_old.o"
new_obj="${out_dir}/hcr_new.o"
evidence="${out_dir}/compile-commands.txt"

printf 'schema_id=reprobuild.hcr.object-fixture-commands.v1\n' > "${evidence}"
printf 'compiler=%s\n' "${cc_bin}" >> "${evidence}"
printf 'common_flags=-c -g -O0 -ffunction-sections -fpatchable-function-entry=8,4\n' >> "${evidence}"
printf 'old_command=' >> "${evidence}"
printf '%q ' "${cc_bin}" "${common_flags[@]}" "${script_dir}/hcr_old.c" -o "${old_obj}" >> "${evidence}"
printf '\n' >> "${evidence}"
printf 'new_command=' >> "${evidence}"
printf '%q ' "${cc_bin}" "${common_flags[@]}" "${script_dir}/hcr_new.c" -o "${new_obj}" >> "${evidence}"
printf '\n' >> "${evidence}"
printf 'positive_path=relocatable-object\n' >> "${evidence}"
printf 'shared_library_loading_positive_path=forbidden\n' >> "${evidence}"

"${cc_bin}" "${common_flags[@]}" "${script_dir}/hcr_old.c" -o "${old_obj}"
"${cc_bin}" "${common_flags[@]}" "${script_dir}/hcr_new.c" -o "${new_obj}"

printf 'old_object=%s\n' "${old_obj}" >> "${evidence}"
printf 'new_object=%s\n' "${new_obj}" >> "${evidence}"
