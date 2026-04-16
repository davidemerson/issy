COMMENT =	tiny text editor that looks like a printed page

GH_ACCOUNT =	davidemerson
GH_PROJECT =	issy
GH_TAGNAME =	v0.1.1
DISTNAME =	issy-0.1.1

CATEGORIES =	editors
HOMEPAGE =	https://github.com/davidemerson/issy

MAINTAINER =	David Emerson <d@nnix.com>

# BSD 3-Clause
PERMIT_PACKAGE =	Yes

# zig itself is only packaged on amd64 and arm64 in the current ports
# tree (see lang/zig), so those are the only arches issy can currently
# build on.
ONLY_FOR_ARCHS =	amd64 arm64

BUILD_DEPENDS =		lang/zig

WANTLIB +=		c

# zig build is a self-contained build driver: no configure, no make.
# The upstream project has its own test suite that runs under
# `zig build test`.
NO_TEST =		No

# Keep zig's cache out of $HOME (ports builds run unprivileged without
# a writable home). Mirrors the lang/zig port's own invocation style.
MAKE_ENV +=		ZIG_GLOBAL_CACHE_DIR=${WRKBUILD}/zig-global-cache \
			ZIG_LOCAL_CACHE_DIR=${WRKBUILD}/zig-local-cache

do-build:
	cd ${WRKSRC} && ${SETENV} ${MAKE_ENV} \
		zig build -Doptimize=ReleaseSafe

do-install:
	${INSTALL_PROGRAM} ${WRKSRC}/zig-out/bin/issy \
		${PREFIX}/bin/issy
	${INSTALL_MAN} ${WRKSRC}/issy.1 \
		${PREFIX}/man/man1/issy.1

do-test:
	cd ${WRKSRC} && ${SETENV} ${MAKE_ENV} \
		zig build test

.include <bsd.port.mk>
