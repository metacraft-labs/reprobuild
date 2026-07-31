#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 STAGE_DIR SOURCE_MIRROR_ROOT SOURCE_GLIBC_LOADER [EXTRA_ELF ...]" >&2
  exit 64
fi

stage_dir="${1%/}"
source_root="${2%/}"
source_glibc_loader="$3"
shift 3
extra_elfs=("$@")

case "$source_root" in
  "$stage_dir"/*) ;;
  *)
    echo "[normalize-source-runtime] source mirror escapes stage: $source_root" >&2
    exit 64
    ;;
esac

patchelf_bin="$(command -v patchelf || true)"
if [ -z "$patchelf_bin" ]; then
  echo "[normalize-source-runtime] patchelf not found" >&2
  exit 70
fi

source_glibc_loader_staged="$stage_dir$source_glibc_loader"
source_glibc_dir="$(dirname "$source_glibc_loader")"
if [ ! -x "$source_glibc_loader_staged" ] || \
   [ ! -e "$stage_dir$source_glibc_dir/libc.so.6" ]; then
  echo "[normalize-source-runtime] incomplete source glibc: $source_glibc_dir" >&2
  exit 65
fi
source_glibc_version="$("$source_glibc_loader_staged" --version 2>&1 | \
  sed -nE 's/.*version ([0-9]+\.[0-9]+).*/\1/p' | head -n1)"
if [ -z "$source_glibc_version" ]; then
  echo "[normalize-source-runtime] could not determine source glibc version" >&2
  exit 65
fi

runtime_source_root="${source_root#$stage_dir}"
declare -A source_provider=()
declare -A provider_conflicts=()

while IFS= read -r -d '' library; do
  name="$(basename "$library")"
  runtime_path="${library#$stage_dir}"
  if [ -z "${source_provider[$name]:-}" ]; then
    source_provider["$name"]="$runtime_path"
  elif [ "${source_provider[$name]}" != "$runtime_path" ]; then
    provider_conflicts["$name"]=1
  fi
done < <(
  find "$source_root" \( -type f -o -type l \) -name '*.so*' -print0 2>/dev/null | \
    sort -z
)

echo "[normalize-source-runtime] indexed ${#source_provider[@]} source library names"
echo "[normalize-source-runtime] duplicate names=${#provider_conflicts[@]}"

candidates_file="$(mktemp -t reproos-source-runtime-candidates-XXXXXX)"
missing_file="$(mktemp -t reproos-source-runtime-missing-XXXXXX)"
leaks_file="$(mktemp -t reproos-source-runtime-leaks-XXXXXX)"
shebang_plan_file="$(mktemp -t reproos-source-runtime-shebang-plan-XXXXXX)"
trap 'rm -f "$candidates_file" "$missing_file" "$leaks_file" "$shebang_plan_file"' EXIT

find "$source_root" -type f \
  \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) \
  -print 2>/dev/null > "$candidates_file"
for extra_elf in "${extra_elfs[@]}"; do
  [ -f "$extra_elf" ] && printf '%s\n' "$extra_elf" >> "$candidates_file"
done
sort -u -o "$candidates_file" "$candidates_file"

is_elf() {
  local file="$1"
  local magic=""
  IFS= read -r -N 4 magic < "$file" 2>/dev/null || true
  [ "$magic" = $'\177ELF' ]
}

plan_runtime_shebangs() {
  local plan_file="$1"
  local error_file="$2"
  local executable runtime_path first_line shebang_re interpreter args target
  shebang_re='^#![[:space:]]*(/usr/bin/env[[:space:]]+)?([^[:space:]]+)([[:space:]].*)?$'
  while IFS= read -r -d '' executable; do
    runtime_path="${executable#"$stage_dir"}"
    case "$runtime_path" in
      /nix/*|/repro/store/*) continue ;;
    esac
    first_line=""
    IFS= read -r first_line < "$executable" 2>/dev/null || true
    case "$first_line" in
      '#!'*'/nix/store/'*|'#!'*'/repro/store/'*|'#!'*'/run/current-system/sw/'*) ;;
      *) continue ;;
    esac
    if [[ ! "$first_line" =~ $shebang_re ]]; then
      printf 'unsupported-shebang:%s\t%s\n' \
        "$first_line" "$runtime_path" >> "$error_file"
      continue
    fi
    interpreter="${BASH_REMATCH[2]}"
    args="${BASH_REMATCH[3]:-}"
    case "$interpreter" in
      */bin/bash) target=/usr/bin/bash ;;
      */bin/sh) target=/usr/bin/sh ;;
      */bin/python*) target=/usr/bin/python3 ;;
      */bin/perl*) target=/usr/bin/perl ;;
      */bin/gawk|*/bin/awk) target=/usr/bin/gawk ;;
      *)
        printf 'unsupported-shebang-interpreter:%s\t%s\n' \
          "$interpreter" "$runtime_path" >> "$error_file"
        continue
        ;;
    esac
    if [ ! -x "$stage_dir$target" ]; then
      printf 'missing-shebang-interpreter:%s\t%s\n' \
        "$target" "$runtime_path" >> "$error_file"
      continue
    fi
    printf '%s\t#!%s%s\n' "$executable" "$target" "$args" >> "$plan_file"
  done < <(
    find "$stage_dir" -type f -perm /111 -print0 2>/dev/null
  )
}

record_runtime_shebang_leaks() {
  local output_file="$1"
  local executable runtime_path first_line
  while IFS= read -r -d '' executable; do
    runtime_path="${executable#"$stage_dir"}"
    case "$runtime_path" in
      /nix/*|/repro/store/*) continue ;;
    esac
    first_line=""
    IFS= read -r first_line < "$executable" 2>/dev/null || true
    case "$first_line" in
      '#!'*'/nix/store/'*|'#!'*'/repro/store/'*|'#!'*'/run/current-system/sw/'*)
        printf 'runtime-shebang:%s\t%s\n' \
          "$first_line" "$runtime_path" >> "$output_file"
        ;;
    esac
  done < <(
    find "$stage_dir" -type f -perm /111 -print0 2>/dev/null
  )
}

is_compatible_bootstrap_glibc() {
  local interpreter="$1"
  local bootstrap_version oldest_version
  if [[ "$interpreter" =~ ^/(nix|repro)/store/[^/]+-glibc-([0-9]+\.[0-9]+)(-[^/]*)?/lib[^/]*/ld-linux[^/]*\.so ]]; then
    bootstrap_version="${BASH_REMATCH[2]}"
  else
    return 0
  fi
  oldest_version="$(printf '%s\n%s\n' \
    "$bootstrap_version" "$source_glibc_version" | sort -V | head -n1)"
  [ "$oldest_version" = "$bootstrap_version" ]
}

while IFS= read -r elf; do
  is_elf "$elf" || continue
  interpreter="$("$patchelf_bin" --print-interpreter "$elf" 2>/dev/null || true)"
  if [ -n "$interpreter" ] && \
     ! is_compatible_bootstrap_glibc "$interpreter"; then
    printf 'incompatible-interpreter:%s\t%s\n' \
      "$interpreter" "${elf#$stage_dir}" >> "$missing_file"
  fi
  while IFS= read -r needed; do
    [ -n "$needed" ] || continue
    if [ -z "${source_provider[$needed]:-}" ]; then
      printf '%s\t%s\n' "$needed" "${elf#$stage_dir}" >> "$missing_file"
    fi
  done < <("$patchelf_bin" --print-needed "$elf" 2>/dev/null || true)
done < "$candidates_file"

while IFS= read -r symlink; do
  printf 'store-symlink:%s\t%s\n' \
    "$(readlink "$symlink")" "${symlink#$stage_dir}" >> "$missing_file"
done < <(
  find "$source_root" -type l \
    \( -lname '/nix/store/*' -o -lname '/repro/store/*' \) \
    -print 2>/dev/null
)

plan_runtime_shebangs "$shebang_plan_file" "$missing_file"

if [ -s "$missing_file" ]; then
  missing_count="$(wc -l < "$missing_file")"
  echo "[normalize-source-runtime] missing $missing_count source runtime edges:" >&2
  sort -u "$missing_file" | sed -n '1,100p' >&2
  exit 75
fi

rewritten_shebangs=0
while IFS=$'\t' read -r executable replacement; do
  [ -n "$executable" ] || continue
  replacement_file="${executable}.repro-shebang.$$"
  {
    printf '%s\n' "$replacement"
    tail -n +2 "$executable"
  } > "$replacement_file"
  chmod --reference="$executable" "$replacement_file"
  touch --reference="$executable" "$replacement_file"
  mv -f "$replacement_file" "$executable"
  rewritten_shebangs=$((rewritten_shebangs + 1))
done < "$shebang_plan_file"
echo "[normalize-source-runtime] rewrote $rewritten_shebangs runtime shebangs"

normalized=0
inspected=0
while IFS= read -r elf; do
  is_elf "$elf" || continue
  inspected=$((inspected + 1))

  old_rpath="$("$patchelf_bin" --print-rpath "$elf" 2>/dev/null || true)"
  old_interpreter="$("$patchelf_bin" --print-interpreter "$elf" 2>/dev/null || true)"
  declare -A rpath_seen=()
  new_rpaths=()

  add_rpath() {
    local path="$1"
    [ -n "$path" ] || return 0
    if [ -z "${rpath_seen[$path]:-}" ]; then
      rpath_seen["$path"]=1
      new_rpaths+=("$path")
    fi
  }

  IFS=: read -r -a old_rpaths <<< "$old_rpath"
  for path in "${old_rpaths[@]}"; do
    case "$path" in
      '$ORIGIN'*)
        add_rpath "$path"
        ;;
      "$runtime_source_root"/*/.repro/output/install/*|/usr/lib*|/lib*)
        add_rpath "$path"
        ;;
      /nix/store/*|/repro/store/*)
        host_path="$path"
        case "$path" in
          /repro/store/*) host_path="$stage_dir$path" ;;
        esac
        mapped=0
        if [ -d "$host_path" ]; then
          shopt -s nullglob
          for library in "$host_path"/*.so*; do
            [ -f "$library" ] || [ -L "$library" ] || continue
            name="$(basename "$library")"
            provider="${source_provider[$name]:-}"
            [ -n "$provider" ] || continue
            add_rpath "$(dirname "$provider")"
            mapped=1
          done
          shopt -u nullglob
        fi
        if [ "$mapped" = 0 ]; then
          echo "[normalize-source-runtime] dropping unused store RPATH: $path ($elf)"
        fi
        ;;
      "$runtime_source_root"/*/build/*|/opt/repro/reprobuild/outputs/*)
        ;;
      "")
        ;;
      *)
        echo "[normalize-source-runtime] dropping unstaged RPATH: $path ($elf)"
        ;;
    esac
  done

  while IFS= read -r needed; do
    [ -n "$needed" ] || continue
    provider="${source_provider[$needed]:-}"
    if [ -z "$provider" ]; then
      echo "[normalize-source-runtime] provider disappeared for $needed" >&2
      exit 75
    fi
    add_rpath "$(dirname "$provider")"
  done < <("$patchelf_bin" --print-needed "$elf" 2>/dev/null || true)

  chmod u+w "$elf" 2>/dev/null || true
  if [ -n "$old_interpreter" ]; then
    if ! is_compatible_bootstrap_glibc "$old_interpreter"; then
      echo "[normalize-source-runtime] source glibc $source_glibc_version is older than $old_interpreter" >&2
      exit 75
    fi
    "$patchelf_bin" --set-interpreter "$source_glibc_loader" "$elf"
    add_rpath "$source_glibc_dir"
  fi

  new_rpath=""
  if [ "${#new_rpaths[@]}" -gt 0 ]; then
    new_rpath="$(IFS=:; printf '%s' "${new_rpaths[*]}")"
  fi
  if [ -n "$new_rpath" ]; then
    "$patchelf_bin" --set-rpath "$new_rpath" "$elf"
  else
    "$patchelf_bin" --remove-rpath "$elf" 2>/dev/null || true
  fi
  normalized=$((normalized + 1))
  unset -f add_rpath
done < "$candidates_file"

while IFS= read -r elf; do
  is_elf "$elf" || continue
  rpath="$("$patchelf_bin" --print-rpath "$elf" 2>/dev/null || true)"
  interpreter="$("$patchelf_bin" --print-interpreter "$elf" 2>/dev/null || true)"
  if [[ "$rpath:$interpreter" == *"/nix/store/"* ]] || \
     [[ "$rpath:$interpreter" == *"/repro/store/"* ]] || \
     [[ "$rpath" == *"/build/out/"* ]]; then
    printf '%s\tRPATH=%s\tINTERP=%s\n' \
      "${elf#$stage_dir}" "$rpath" "$interpreter" >> "$leaks_file"
  fi
done < "$candidates_file"

find "$source_root" -type l \
  \( -lname '/nix/store/*' -o -lname '/repro/store/*' \) \
  -printf '%p\tTARGET=%l\n' 2>/dev/null >> "$leaks_file" || true

record_runtime_shebang_leaks "$leaks_file"

if [ -s "$leaks_file" ]; then
  leak_count="$(wc -l < "$leaks_file")"
  echo "[normalize-source-runtime] found $leak_count runtime store leaks:" >&2
  head -100 "$leaks_file" >&2
  exit 75
fi

echo "[normalize-source-runtime] normalized $normalized of $inspected inspected ELFs"
echo "[normalize-source-runtime] verified source-only ELF runtime closure"
