#!/usr/bin/env bash
# Cross-compiles the libraries EasyRPG Player needs for the PlayStation Portable
# and installs them into ${PSPDEV}/psp.
#
# The pspdev image already ships zlib, libpng, pixman and fmt in ${PSPDEV}/psp,
# so only inih and liblcf are built here. Missing libraries are built too.
#
# Usage: PSPDEV=/usr/local/pspdev builds/psp/build-deps.sh
#
# Needs: git, cmake, make or ninja, the pspdev toolchain. meson is only needed
# when pixman is missing from the sysroot.

set -euo pipefail

export PSPDEV="${PSPDEV:-/usr/local/pspdev}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLCHAIN="${ROOT}/builds/psp/PspToolchain.cmake"
PREFIX="${PSPDEV}/psp"
WORK="${PSP_DEPS_WORK:-${ROOT}/psp-deps}"
JOBS="${JOBS:-$(nproc)}"

# Pinned versions
ZLIB_REF=v1.3.1
LIBPNG_REF=v1.6.43
PIXMAN_VERSION=0.44.2
FMT_REF=10.2.1
INIH_REF=r58
LHASA_REF=v0.5.0
SPEEXDSP_REF=SpeexDSP-1.2.1
SNDFILE_REF=1.2.2
JSON_REF=v3.11.3
ICU_REF=release-74-2
LIBLCF_REF="${LIBLCF_REF:-master}"  # same branch the stable CI builds (PLAYER_BUILD_LIBLCF_BRANCH)

mkdir -p "${WORK}"

# Generator: Ninja when available, the default one otherwise
GENERATOR=()
if command -v ninja >/dev/null 2>&1; then
	GENERATOR=(-G Ninja)
fi

log() {
	echo "==> $1"
}

fetch_git() { # <url> <ref> <name>
	if [[ ! -d "${WORK}/$3" ]]; then
		git clone --depth 1 --branch "$2" "$1" "${WORK}/$3"
	fi
}

cmake_lib() { # <name> <source dir> <extra cmake args...>
	local name=$1 src=$2
	shift 2
	cmake -S "${src}" -B "${WORK}/build-${name}" "${GENERATOR[@]}" \
		-DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="${PREFIX}" \
		-DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		"$@"
	cmake --build "${WORK}/build-${name}" --parallel "${JOBS}"
	cmake --install "${WORK}/build-${name}"
}

# True when the sysroot already has the library and its header
have_sysroot() { # <library file> <header>
	[[ -f "${PREFIX}/lib/$1" && -f "${PREFIX}/include/$2" ]]
}

# zlib
if have_sysroot libz.a zlib.h; then
	log "zlib: already in ${PREFIX}"
else
	log "zlib ${ZLIB_REF}"
	fetch_git https://github.com/madler/zlib.git "${ZLIB_REF}" zlib
	cmake_lib zlib "${WORK}/zlib" -DZLIB_BUILD_TESTING=OFF
fi

# libpng (needs zlib)
if have_sysroot libpng.a png.h; then
	log "libpng: already in ${PREFIX}"
else
	log "libpng ${LIBPNG_REF}"
	fetch_git https://github.com/pnggroup/libpng.git "${LIBPNG_REF}" libpng
	cmake_lib libpng "${WORK}/libpng" \
		-DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
fi

# pixman (meson only). No threads, no SIMD: the Allegrex CPU has neither.
if have_sysroot libpixman-1.a pixman-1/pixman.h; then
	log "pixman: already in ${PREFIX}"
else
	log "pixman ${PIXMAN_VERSION}"
	if [[ ! -d "${WORK}/pixman-${PIXMAN_VERSION}" ]]; then
		curl -fsSL "https://cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz" \
			| tar -xz -C "${WORK}"
	fi
	cat > "${WORK}/psp-cross.ini" <<EOF
[binaries]
c = '${PSPDEV}/bin/psp-gcc'
cpp = '${PSPDEV}/bin/psp-g++'
ar = '${PSPDEV}/bin/psp-ar'
strip = '${PSPDEV}/bin/psp-strip'

[host_machine]
system = 'generic'
cpu_family = 'mips'
cpu = 'allegrex'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
	meson setup "${WORK}/build-pixman" "${WORK}/pixman-${PIXMAN_VERSION}" \
		--cross-file "${WORK}/psp-cross.ini" \
		--prefix "${PREFIX}" \
		--default-library static \
		--buildtype release \
		-Dopenmp=disabled -Dtls=disabled -Dgtk=disabled -Dlibpng=disabled \
		-Dtests=disabled -Ddemos=disabled \
		-Dmmx=disabled -Dsse2=disabled -Dssse3=disabled -Dvmx=disabled \
		-Darm-simd=disabled -Dneon=disabled -Da64-neon=disabled \
		-Dmips-dspr2=disabled -Dloongson-mmi=disabled
	ninja -C "${WORK}/build-pixman" -j "${JOBS}"
	ninja -C "${WORK}/build-pixman" install
fi

# fmt
if have_sysroot libfmt.a fmt/format.h; then
	log "fmt: already in ${PREFIX}"
else
	log "fmt ${FMT_REF}"
	fetch_git https://github.com/fmtlib/fmt.git "${FMT_REF}" fmt
	cmake_lib fmt "${WORK}/fmt" -DFMT_TEST=OFF -DFMT_DOC=OFF
fi

# inih: upstream has no CMake file at this tag. liblcf needs ini.c and the
# INIReader C++ wrapper, so a small CMake project builds and installs them.
log "inih ${INIH_REF}"
fetch_git https://github.com/benhoyt/inih.git "${INIH_REF}" inih
mkdir -p "${WORK}/inih-cmake"
cat > "${WORK}/inih-cmake/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(inih C CXX)
add_library(inih STATIC "${WORK}/inih/ini.c" "${WORK}/inih/cpp/INIReader.cpp")
target_include_directories(inih PUBLIC "${WORK}/inih" "${WORK}/inih/cpp")
install(TARGETS inih ARCHIVE DESTINATION lib)
install(FILES "${WORK}/inih/ini.h" "${WORK}/inih/cpp/INIReader.h" DESTINATION include)
EOF
cmake_lib inih "${WORK}/inih-cmake" -DINI_INITIAL_ALLOC=200

# nlohmann_json (header only), used for JSON game data
log "nlohmann_json ${JSON_REF}"
fetch_git https://github.com/nlohmann/json.git "${JSON_REF}" json
cmake_lib json "${WORK}/json" -DJSON_BuildTests=OFF -DJSON_Install=ON

# SpeexDSP resampler for sounds that are not 44.1 kHz. (libsamplerate works too, but its
# filter tables alone take 1.4 MB of the PSP's small RAM.) Upstream only has autotools and the
# resampler is one self contained file, so a small CMake project builds it.
log "speexdsp ${SPEEXDSP_REF}"
fetch_git https://github.com/xiph/speexdsp.git "${SPEEXDSP_REF}" speexdsp
mkdir -p "${WORK}/speexdsp-cmake/include/speex"
cat > "${WORK}/speexdsp-cmake/include/speex/speexdsp_config_types.h" <<'SPEEX_TYPES'
#ifndef __SPEEX_TYPES_H__
#define __SPEEX_TYPES_H__
#include <stdint.h>
typedef int16_t spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t spx_int32_t;
typedef uint32_t spx_uint32_t;
#endif
SPEEX_TYPES
cat > "${WORK}/speexdsp-cmake/CMakeLists.txt" <<SPEEX_CMAKE
cmake_minimum_required(VERSION 3.16)
project(speexdsp C)
add_library(speexdsp STATIC "${WORK}/speexdsp/libspeexdsp/resample.c")
target_compile_definitions(speexdsp PRIVATE FLOATING_POINT "EXPORT=")
target_include_directories(speexdsp PRIVATE "${WORK}/speexdsp/include" "${WORK}/speexdsp/include/speex"
	"${WORK}/speexdsp/libspeexdsp" "${WORK}/speexdsp-cmake/include" "${WORK}/speexdsp-cmake/include/speex")
file(GLOB SPEEX_HEADERS "${WORK}/speexdsp/include/speex/*.h")
install(TARGETS speexdsp ARCHIVE DESTINATION lib)
install(FILES \${SPEEX_HEADERS} "${WORK}/speexdsp-cmake/include/speex/speexdsp_config_types.h"
	DESTINATION include/speex)
SPEEX_CMAKE
cmake_lib speexdsp "${WORK}/speexdsp-cmake"

# libsndfile: more WAV/AIFF/AU variants. The compressed formats (FLAC, Vorbis, Opus, MP3) are
# handled by the dedicated decoders already, so no external libraries are used.
log "libsndfile ${SNDFILE_REF}"
fetch_git https://github.com/libsndfile/libsndfile.git "${SNDFILE_REF}" libsndfile
CFLAGS="-Wno-error=incompatible-pointer-types" cmake_lib libsndfile "${WORK}/libsndfile" \
	-DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_REGTEST=OFF \
	-DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DENABLE_CPACK=OFF -DINSTALL_MANPAGES=OFF

# lhasa (LZH archives): upstream only has autotools, build the library with a small CMake project
log "lhasa ${LHASA_REF}"
fetch_git https://github.com/fragglet/lhasa.git "${LHASA_REF}" lhasa
mkdir -p "${WORK}/lhasa-cmake"
cat > "${WORK}/lhasa-cmake/CMakeLists.txt" <<LHASA_CMAKE
cmake_minimum_required(VERSION 3.16)
project(lhasa C)
set(LHASA_SOURCES crc16 ext_header lha_arch_unix lha_decoder lha_endian lha_file_header
	lha_input_stream lha_basic_reader lha_reader macbinary null_decoder lh1_decoder lh5_decoder
	lh6_decoder lh7_decoder lhx_decoder lk7_decoder lz5_decoder lzs_decoder pm1_decoder pm2_decoder)
list(TRANSFORM LHASA_SOURCES PREPEND "${WORK}/lhasa/lib/")
list(TRANSFORM LHASA_SOURCES APPEND ".c")
add_library(lhasa STATIC \${LHASA_SOURCES})
target_include_directories(lhasa PRIVATE "${WORK}/lhasa/lib" "${WORK}/lhasa/lib/public")
file(GLOB LHASA_HEADERS "${WORK}/lhasa/lib/public/*.h")
install(TARGETS lhasa ARCHIVE DESTINATION lib)
install(FILES \${LHASA_HEADERS} DESTINATION include/liblhasa)
LHASA_CMAKE
cmake_lib lhasa "${WORK}/lhasa-cmake"

# ICU: liblcf needs it to decode the text of games in GBK, Big5, Shift-JIS, ... and to detect the
# encoding. It is a two stage build: tools for the build machine first (static, they also create
# the data), then the PSP libraries (the linux style host name only selects ICU's generic
# POSIX make fragment, the platform is detected from the compiler at build time). The data filter keeps only the charset converters and
# normalization, ~1 MB instead of ~30 MB. ICU_SRC_DIR and ICU_HOST_DIR can point to an existing
# ICU checkout and finished host build (the host build has to be at the same path).
ICU_ROOT="${ICU_SRC_DIR:-${WORK}/icu}"
ICU_SRC="${ICU_ROOT}/icu4c/source"
ICU_HOST="${ICU_HOST_DIR:-${WORK}/icu-host-build}"
ICU_FILTER="${ROOT}/builds/psp/icu-data-filter.json"
if [[ ! -f "${PREFIX}/lib/libicuuc.a" ]]; then
	log "ICU ${ICU_REF}"
	if [[ ! -d "${ICU_ROOT}" ]]; then
		git clone --depth 1 --branch "${ICU_REF}" https://github.com/unicode-org/icu.git "${ICU_ROOT}"
	fi
	if [[ ! -x "${ICU_HOST}/bin/icupkg" ]]; then
		if ! command -v g++ >/dev/null || ! command -v python3 >/dev/null; then
			echo "Building ICU needs a C++ compiler and python3 for the build machine," \
				"or set ICU_HOST_DIR to a finished host build." >&2
			exit 1
		fi
		mkdir -p "${ICU_HOST}"
		(cd "${ICU_HOST}" && \
			ICU_DATA_FILTER_FILE="${ICU_FILTER}" CFLAGS=-O2 CXXFLAGS=-O2 LDFLAGS=-static \
			"${ICU_SRC}/runConfigureICU" Linux --enable-static --disable-shared \
				--disable-tests --disable-samples --disable-extras --disable-layoutex \
				--disable-icuio --with-data-packaging=static && \
			make -j"${JOBS}")
	fi
	# newlib has int32_t as long, one place in ICU does not cope with that
	ICU_PATCH="${ROOT}/builds/psp/patches/icu-newlib.patch"
	if git -C "${ICU_ROOT}" apply --check "${ICU_PATCH}" 2>/dev/null; then
		git -C "${ICU_ROOT}" apply "${ICU_PATCH}"
	fi
	# The formatting, collation, break iteration, transliteration, regular expression and IDNA
	# parts of ICU are not needed (and do not build with newlib's int32_t); this also saves a lot
	# of code. What stays: charset conversion, charset detection and normalization.
	ICU_FEATURES="-DUCONFIG_NO_FORMATTING=1 -DUCONFIG_NO_COLLATION=1 -DUCONFIG_NO_BREAK_ITERATION=1"
	ICU_FEATURES="${ICU_FEATURES} -DUCONFIG_NO_TRANSLITERATION=1 -DUCONFIG_NO_REGULAR_EXPRESSIONS=1"
	ICU_FEATURES="${ICU_FEATURES} -DUCONFIG_NO_IDNA=1 -DU_CHARSET_IS_UTF8=0"
	# The data was made by the host build; the target build packages that archive (this is the
	# way ICU's release tarballs work, they ship data/in/icudt*.dat)
	cp "${ICU_HOST}/data/out/tmp/icudt74l.dat" "${ICU_SRC}/data/in/icudt74l.dat"
	mkdir -p "${WORK}/build-icu"
	(cd "${WORK}/build-icu" && \
		ICU_DATA_FILTER_FILE="${ICU_FILTER}" \
		CC="${PSPDEV}/bin/psp-gcc" CXX="${PSPDEV}/bin/psp-g++" \
		AR="${PSPDEV}/bin/psp-ar" RANLIB="${PSPDEV}/bin/psp-ranlib" \
		CFLAGS="-O2" CXXFLAGS="-O2" CPPFLAGS="${ICU_FEATURES}" \
		"${ICU_SRC}/configure" --host=mipsel-unknown-linux-gnu --with-cross-build="${ICU_HOST}" \
			--prefix="${PREFIX}" --enable-static --disable-shared --disable-tools \
			--disable-tests --disable-samples --disable-extras --disable-layoutex \
			--disable-icuio --with-data-packaging=static && \
		# Static data as C source, not position independent assembly: the PSP toolchain does not
		# do PIC code
		sed -i 's/ -DPIC -fPIC//; s/^GENCCODE_ASSEMBLY_TYPE=.*/GENCCODE_ASSEMBLY_TYPE=/' data/icupkg.inc && \
		make -j"${JOBS}" && make install)
else
	log "ICU: already in ${PREFIX}"
fi

# liblcf: with ICU, no XML (expat) and no tools.
log "liblcf ${LIBLCF_REF}"
fetch_git https://github.com/EasyRPG/liblcf.git "${LIBLCF_REF}" liblcf
cmake_lib liblcf "${WORK}/liblcf" \
	-DLIBLCF_WITH_ICU=ON \
	-DLIBLCF_WITH_XML=OFF \
	-DLIBLCF_WITH_INI=ON \
	-DLIBLCF_ENABLE_TOOLS=OFF \
	-DLIBLCF_ENABLE_TESTS=OFF \
	-DLIBLCF_UPDATE_MIMEDB=OFF \
	-DLIBLCF_ENABLE_INSTALL=ON

echo "PSP dependencies installed into ${PREFIX}"
