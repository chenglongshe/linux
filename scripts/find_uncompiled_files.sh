#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# find_uncompiled_files.sh
#
# Find .c and .h files under a specified directory that did not participate
# in the kernel compilation process. Results are written to an output file
# with paths relative to the kernel source root.
#
# 功能说明：
#   在指定目录（如 drivers/）下查找所有没有参与内核编译过程的 .c 和 .h 文件，
#   并将这些文件的路径记录到输出文件中。
#
# 实现逻辑（三步对比法）：
#
#   第一步 - 枚举源文件：
#     使用 find 命令遍历目标目录，收集所有 .c 和 .h 文件的路径，
#     生成"源文件全集"（all_source.txt）。
#
#   第二步 - 提取编译记录：
#     内核编译时，构建系统（Kbuild）会为每个编译单元生成 .cmd 依赖文件。
#     例如编译 drivers/android/binder.c 时，会产生：
#       drivers/android/.binder.o.cmd
#     该文件由 scripts/basic/fixdep 工具生成，内容格式如下：
#
#       savedcmd_drivers/android/binder.o := gcc ... -c -o binder.o binder.c
#       source_drivers/android/binder.o := drivers/android/binder.c
#       deps_drivers/android/binder.o := \
#         drivers/android/binder.c \
#         drivers/android/binder_internal.h \
#         drivers/android/binder_alloc.h \
#         include/linux/types.h \
#         ...
#
#     其中 deps_<target> 包含了该编译单元涉及的所有源文件和头文件路径。
#     脚本扫描构建目录下所有 .*.cmd 文件，用正则表达式提取其中的
#     .c 和 .h 文件路径，生成"已编译文件集"（compiled_files.txt）。
#
#   第三步 - 差集比较：
#     使用 comm -23 命令对两个有序列表取差集：
#       comm -23 all_source.txt compiled_files.txt
#     即：在"源文件全集"中存在、但在"已编译文件集"中不存在的文件，
#     就是没有参与编译的文件。结果写入输出文件。
#
# .cmd 文件的生成机制：
#   1. Kbuild 的 scripts/Makefile.build 定义了 %.o: %.c 的编译规则
#   2. 编译时调用 cmd_and_fixdep，先执行 gcc 编译，再调用 fixdep
#   3. fixdep (scripts/basic/fixdep.c) 解析 gcc -MD 生成的 .d 依赖文件
#   4. fixdep 将依赖信息转换为 .cmd 格式，记录到 $(dir $@).$(notdir $@).cmd
#   5. .cmd 文件中的 deps_<target> 包含所有直接和间接依赖的源文件和头文件
#
# Prerequisites:
#   - The kernel must have been built (so .cmd files exist)
#   - Run this script from the kernel source tree root
#   （前提条件：需要先编译内核以生成 .cmd 文件，并在源码树根目录下运行）
#
# Usage:
#   scripts/find_uncompiled_files.sh -d <directory> [-o <output>] [-B <build_dir>]
#
# Options:
#   -d DIR     Directory to scan, relative to source root (e.g., drivers)
#              要扫描的目录，相对于源码根目录（如 drivers）
#   -o FILE    Output file (default: uncompiled_files.txt)
#              输出文件路径（默认: uncompiled_files.txt）
#   -B DIR     Build output directory for out-of-tree builds (default: .)
#              构建输出目录，用于支持 out-of-tree 编译（默认: .）
#
# Examples:
#   scripts/find_uncompiled_files.sh -d drivers
#   scripts/find_uncompiled_files.sh -d drivers -o unused_drivers.txt
#   scripts/find_uncompiled_files.sh -d drivers -B /path/to/build/output
#
# Output format (one file per line):
#   drivers/android/dbitmap.h
#   drivers/some/unused_driver.c

set -e

TARGET_DIR=""
OUTPUT_FILE="uncompiled_files.txt"
BUILD_DIR="."

usage() {
	cat <<EOF
Usage: $0 -d <directory> [-o <output_file>] [-B <build_dir>]

Find .c and .h files not participating in kernel compilation.

Options:
  -d DIR     Directory to scan, relative to source root (e.g., drivers)
  -o FILE    Output file (default: uncompiled_files.txt)
  -B DIR     Build output directory for out-of-tree builds (default: .)
  -h         Show this help message

Example:
  $0 -d drivers
  $0 -d drivers -o unused_drivers.txt -B /path/to/build

Output format (one file per line):
  drivers/android/dbitmap.h
  drivers/some/unused_driver.c
EOF
	exit "${1:-1}"
}

while getopts "d:o:B:h" opt; do
	case $opt in
	d)
		TARGET_DIR="$OPTARG"
		;;
	o)
		OUTPUT_FILE="$OPTARG"
		;;
	B)
		BUILD_DIR="$OPTARG"
		;;
	h)
		usage 0
		;;
	*)
		usage 1
		;;
	esac
done

if [ -z "$TARGET_DIR" ]; then
	echo "Error: -d <directory> is required." >&2
	usage 1
fi

# Normalize paths - remove trailing slashes
TARGET_DIR="${TARGET_DIR%/}"
BUILD_DIR="${BUILD_DIR%/}"

if [ ! -d "$TARGET_DIR" ]; then
	echo "Error: '$TARGET_DIR' is not a valid directory." >&2
	exit 1
fi

# Create temporary directory for intermediate files
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Step 1: Find all .c and .h files in the target directory
# 第一步：枚举目标目录下所有 .c 和 .h 源文件，生成"源文件全集"
find "$TARGET_DIR" -type f \( -name '*.c' -o -name '*.h' \) | \
	sort > "$TMP_DIR/all_source.txt"

total=$(wc -l < "$TMP_DIR/all_source.txt")
if [ "$total" -eq 0 ]; then
	echo "No .c or .h files found in '$TARGET_DIR'."
	true > "$OUTPUT_FILE"
	exit 0
fi

# Step 2: Collect all .c and .h file paths referenced during compilation.
# 第二步：从 .cmd 依赖文件中提取所有参与编译的 .c 和 .h 文件路径，
#         生成"已编译文件集"。
#
# The kernel build system generates .cmd files (via fixdep) for each
# compiled object. These files contain dependency lists that record every
# source file and header involved in the compilation:
# 内核构建系统通过 fixdep 为每个编译目标生成 .cmd 文件，
# 其中包含该编译单元的所有源文件和头文件依赖：
#
#   source_<target> := <source.c>
#   deps_<target> := \
#     path/to/source.c \
#     path/to/header.h \
#     ...
#
# We extract all .c and .h paths from these files to build the set of
# files that participated in compilation.
# 我们从这些文件中提取所有 .c 和 .h 路径来构建参与编译的文件集合。

if ! find "$BUILD_DIR" -name '.*.cmd' -type f -print -quit 2>/dev/null | grep -q .; then
	echo "Warning: No .cmd files found in '$BUILD_DIR'." >&2
	echo "The kernel must be built first to generate build metadata." >&2
	echo "Listing all .c and .h files as uncompiled." >&2
	cp "$TMP_DIR/all_source.txt" "$OUTPUT_FILE"
	echo ""
	echo "Results written to: $OUTPUT_FILE"
	echo "Total uncompiled files: $total (no build data available)"
	exit 0
fi

echo "Scanning '$TARGET_DIR' for .c and .h files not used in kernel build..."
echo "Build directory: $BUILD_DIR"

# Extract all .c and .h file paths from .cmd files.
# 从所有 .cmd 文件中用正则提取 .c 和 .h 文件路径。
# The regex matches file paths ending in .c or .h.
# We strip any leading './' to normalize paths.
# 正则匹配以 .c 或 .h 结尾的文件路径，并去除前导 './' 以统一路径格式。
find "$BUILD_DIR" -name '.*.cmd' -type f -print0 2>/dev/null | \
	xargs -0 grep -hoE '[a-zA-Z0-9_/.+-]+\.[ch]' 2>/dev/null | \
	sed 's|^\./||' | \
	sort -u > "$TMP_DIR/compiled_files.txt"

# Step 3: Find files present in the source tree but not referenced
# in any .cmd dependency file - these are the uncompiled files.
# 第三步：取差集 - 在"源文件全集"中存在但不在"已编译文件集"中的文件，
#         即为没有参与编译的文件。
# comm -23: 输出仅在第一个文件中出现的行（即未编译的文件）
comm -23 "$TMP_DIR/all_source.txt" "$TMP_DIR/compiled_files.txt" \
	> "$OUTPUT_FILE"

# Print summary
total_uncompiled=$(wc -l < "$OUTPUT_FILE")
total_c=$(grep -c '\.c$' "$TMP_DIR/all_source.txt" || true)
total_h=$(grep -c '\.h$' "$TMP_DIR/all_source.txt" || true)
uncompiled_c=$(grep -c '\.c$' "$OUTPUT_FILE" || true)
uncompiled_h=$(grep -c '\.h$' "$OUTPUT_FILE" || true)

echo ""
echo "Results written to: $OUTPUT_FILE"
echo "Summary:"
echo "  .c files: $uncompiled_c uncompiled out of $total_c total"
echo "  .h files: $uncompiled_h uncompiled out of $total_h total"
echo "  Total uncompiled: $total_uncompiled out of $total total"
