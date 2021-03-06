#!/bin/bash
# Top-level build script called from Dockerfile

# Stop at any error, show all commands
set -ex

# Set build environment variables
MY_DIR=$(dirname "${BASH_SOURCE[0]}")
. $MY_DIR/build_env.sh

# Dependencies for compiling Python that we want to remove from
# the final image after compiling Python
# GPG installed to verify signatures on Python source tarballs.
PYTHON_COMPILE_DEPS="zlib-devel bzip2-devel ncurses-devel sqlite-devel readline-devel tk-devel gdbm-devel db4-devel libpcap-devel xz-devel gpg libffi-devel"

# Libraries that are allowed as part of the manylinux1 profile
MANYLINUX1_DEPS="glibc-devel libstdc++-devel glib2-devel libX11-devel libXext-devel libXrender-devel  mesa-libGL-devel libICE-devel libSM-devel ncurses-devel zlib-devel"

# Centos 5 is EOL and is no longer available from the usual mirrors, so switch
# to http://vault.centos.org
# From: https://github.com/rust-lang/rust/pull/41045
# The location for version 5 was also removed, so now only the specific release
# (5.11) can be referenced.
sed -i 's/enabled=1/enabled=0/' /etc/yum/pluginconf.d/fastestmirror.conf
sed -i 's/mirrorlist/#mirrorlist/' /etc/yum.repos.d/*.repo
sed -i 's/#\(baseurl.*\)mirror.centos.org\/centos\/$releasever/\1archive.kernel.org\/centos-vault\/5.11/' /etc/yum.repos.d/*.repo

# Get build utilities
source $MY_DIR/build_utils.sh

# Update ca-certs
check_required_source ${CACERT_ROOT}${CACERT_EXTENSION}
check_sha256sum ${CACERT_ROOT}${CACERT_EXTENSION} ${CACERT_HASH}
cp -f ${CACERT_ROOT}${CACERT_EXTENSION} /etc/pki/tls/certs/ca-bundle.crt

# See https://unix.stackexchange.com/questions/41784/can-yum-express-a-preference-for-x86-64-over-i386-packages
echo "multilib_policy=best" >> /etc/yum.conf

# https://hub.docker.com/_/centos/
# "Additionally, images with minor version tags that correspond to install
# media are also offered. These images DO NOT recieve updates as they are
# intended to match installation iso contents. If you choose to use these
# images it is highly recommended that you include RUN yum -y update && yum
# clean all in your Dockerfile, or otherwise address any potential security
# concerns."
# Decided not to clean at this point: https://github.com/pypa/manylinux/pull/129
yum -y update

# EPEL support
# https://dl.fedoraproject.org/pub/epel/5/x86_64/epel-release-5-4.noarch.rpm
rpm -Uvh --replacepkgs $MY_DIR/epel-release-5-4.noarch.rpm
sed -i 's/\(mirrorlist=.*\)/\1\&protocol=http/g' /etc/yum.repos.d/epel*.repo

# Dev toolset (for LLVM and other projects requiring C++11 support)
# http://linuxsoft.cern.ch/cern/devtoolset/slc5-devtoolset.repo
cp $MY_DIR/devtools-2.repo /etc/yum.repos.d/

# Development tools and libraries
yum -y install \
    automake \
    bison \
    bzip2 \
    cmake28 \
    devtoolset-2-binutils \
    devtoolset-2-gcc \
    devtoolset-2-gcc-c++ \
    devtoolset-2-gcc-gfortran \
    diffutils \
    expat-devel \
    gettext \
    file \
    make \
    patch \
    unzip \
    which \
    yasm \
    ${PYTHON_COMPILE_DEPS}

# Build PERL in order to build OpenSSL. We'll delete this after OpenSSL and libxcrypt builds.
build_perl $PERL_ROOT $PERL_HASH

# Build an OpenSSL for both curl and the Pythons. We'll delete this at the end.
build_openssl $OPENSSL_ROOT $OPENSSL_HASH

# Install curl so we can have TLS 1.2 in this ancient container.
build_curl $CURL_ROOT $CURL_HASH
hash -r
curl --version
curl-config --features

# Install newest autoconf
build_autoconf $AUTOCONF_ROOT $AUTOCONF_HASH
autoconf --version

# Install newest automake
build_automake $AUTOMAKE_ROOT $AUTOMAKE_HASH
automake --version

# Install newest libtool
build_libtool $LIBTOOL_ROOT $LIBTOOL_HASH
libtool --version

# Install libcrypt.so.1 and libcrypt.so.2
build_libxcrypt "$LIBXCRYPT_DOWNLOAD_URL" "$LIBXCRYPT_VERSION" "$LIBXCRYPT_HASH"

# Delete PERL now that OpenSSL and libxcrypt are built
rm -rf /opt/perl

# Install a git we link against OpenSSL so that we can use TLS 1.2
build_git $GIT_ROOT $GIT_HASH
git version

# Install a more recent SQLite3
curl -fsSLO $SQLITE_AUTOCONF_DOWNLOAD_URL/$SQLITE_AUTOCONF_ROOT.tar.gz
check_sha256sum $SQLITE_AUTOCONF_ROOT.tar.gz $SQLITE_AUTOCONF_HASH
tar xfz $SQLITE_AUTOCONF_ROOT.tar.gz
cd $SQLITE_AUTOCONF_ROOT
do_standard_install
cd ..
rm -rf $SQLITE_AUTOCONF_ROOT*
rm /usr/local/lib/libsqlite3.a

# Compile the latest Python releases.
# (In order to have a proper SSL module, Python is compiled
# against a recent openssl [see env vars above], which is linked
# statically.
mkdir -p /opt/python
build_cpythons $CPYTHON_VERSIONS

# Create venv for auditwheel & certifi
TOOLS_PATH=/opt/_internal/tools
/opt/python/cp39-cp39/bin/python -m venv $TOOLS_PATH
source $TOOLS_PATH/bin/activate

# Install default packages
pip install -U --require-hashes -r $MY_DIR/requirements3.9.txt
# Install certifi and auditwheel
pip install -U --require-hashes -r $MY_DIR/requirements-tools.txt

# Make auditwheel available in PATH
ln -s $TOOLS_PATH/bin/auditwheel /usr/local/bin/auditwheel
# Make pipx available in PATH,
# Make sure when root installs apps, they're also in the PATH
cat <<EOF > /usr/local/bin/pipx
#!/bin/bash

set -euo pipefail

if [ \$(id -u) -eq 0 ]; then
	export PIPX_BIN_DIR=/usr/local/bin
fi
${TOOLS_PATH}/bin/pipx "\$@"
EOF
chmod 755 /usr/local/bin/pipx

# Our openssl doesn't know how to find the system CA trust store
#   (https://github.com/pypa/manylinux/issues/53)
# And it's not clear how up-to-date that is anyway
# So let's just use the same one pip and everyone uses
ln -s $(python -c 'import certifi; print(certifi.where())') /opt/_internal/certs.pem
# If you modify this line you also have to modify the versions in the Dockerfiles:
export SSL_CERT_FILE=/opt/_internal/certs.pem

# Deactivate the tools virtual environment
deactivate

# Now we can delete our built OpenSSL headers/static libs since we've linked everything we need
rm -rf /usr/local/ssl

# Install patchelf (latest with unreleased bug fixes) and apply our patches
build_patchelf $PATCHELF_VERSION $PATCHELF_HASH

# Clean up development headers and other unnecessary stuff for
# final image
yum -y erase \
    avahi \
    bitstream-vera-fonts \
    freetype \
    gtk2 \
    hicolor-icon-theme \
    libX11 \
    wireless-tools \
    ${PYTHON_COMPILE_DEPS}  > /dev/null 2>&1
yum -y install ${MANYLINUX1_DEPS}
yum -y clean all > /dev/null 2>&1
yum list installed

# Avoid deleting libpython.a as we need it to build Clingo
# find /opt/_internal -name '*.a' -print0 | xargs -0 rm -f

# Strip what we can -- and ignore errors, because this just attempts to strip
# *everything*, including non-ELF files:
find /opt/_internal -type f -print0 \
    | xargs -0 -n1 strip --strip-unneeded 2>/dev/null || true

# We do not need the Python test suites, or indeed the precompiled .pyc and
# .pyo files. Partially cribbed from:
#    https://github.com/docker-library/python/blob/master/3.4/slim/Dockerfile
find /opt/_internal -depth \
     \( -type d -a -name test -o -name tests \) \
  -o \( -type f -a -name '*.pyc' -o -name '*.pyo' \) | xargs rm -rf

for PYTHON in /opt/python/*/bin/python; do
    # Smoke test to make sure that our Pythons work, and do indeed detect as
    # being manylinux compatible:
    $PYTHON $MY_DIR/manylinux1-check.py
    # Make sure that SSL cert checking works
    $PYTHON $MY_DIR/ssl-check.py
done

# Fix libc headers to remain compatible with C99 compilers.
find /usr/include/ -type f -exec sed -i \
    -e 's/\bextern _*inline_*\b/extern __inline __attribute__ ((__gnu_inline__))/g' \
    -e 's/\bextern __always_inline\b/extern __always_inline __attribute__ ((__gnu_inline__))/g' \
    {} +
