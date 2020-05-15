#!/bin/bash
#
# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Install CLIF primer script.

set -x -e

INSTALL_DIR="/usr/local"
CLIFSRC_DIR="$PWD"
LLVM_DIR="$CLIFSRC_DIR/../clif_backend"
BUILD_DIR="$LLVM_DIR/build_matcher"

# Ensure CMake is installed (needs 3.5+)

sudo yum -y install cmake svn clang gcc
sudo pip3 install ninja pyparsing

# Ensure Google protobuf C++ source is installed (needs v3.2+).

PATH=$PATH:/usr/local/bin
PV=$(protoc --version | cut -f2 -d\ ); PV=(${PV//./ })
if (( PV[0] < 3 || PV[0] == 3 && PV[1] < 2 )); then
    echo "Installing Google protobuf version 3.10.1"
    if [ ! -f protobuf.tar.gz ]; then
        curl -L https://github.com/protocolbuffers/protobuf/releases/download/v3.10.1/protobuf-all-3.10.1.tar.gz -o protobuf.tar.gz
        tar -xzf protobuf.tar.gz
    fi
    pushd protobuf-3.10.1
    ./configure --prefix=/usr/local
    make -j "$(($(nproc) * 2))"
    sudo make install
    cd python
    python3 setup.py build
    sudo python3 setup.py install
    popd
fi
PROTOC_PREFIX_PATH="$(dirname "$(dirname "$(which protoc)")")"
printf "/usr/local/lib/\n/usr/local/lib64/" | sudo tee /etc/ld.so.conf.d/local.conf
sudo ldconfig


# If Ninja is installed, use it instead of make.  MUCH faster.

declare -a CMAKE_G_FLAG
declare -a MAKE_PARALLELISM
CMAKE_G_FLAGS=(-G Ninja)
MAKE_OR_NINJA="ninja"
MAKE_PARALLELISM=()  # Ninja does this on its own.
# ninja can run a dozen huge ld processes at once during install without
# this flag... grinding a 12 core workstation with "only" 32GiB to a halt.
# linking and installing should be I/O bound anyways.
MAKE_INSTALL_PARALLELISM=(-j 2)
echo "Using ninja for the clif backend build."

# Determine the Python to use.

if [[ "$1" =~ ^-?-h ]]; then
    echo "Usage: $0 [python interpreter]"
    exit 1
fi
PYTHON="python3"
if [[ -n "$1" ]]; then
    PYTHON="$1"
fi
echo -n "Using Python interpreter: "
which "$PYTHON"

# Create a virtual environment for the pyclif installation.

CLIF_VIRTUALENV="$INSTALL_DIR"/clif
CLIF_PIP="$CLIF_VIRTUALENV/bin/pip"
sudo virtualenv -p "$PYTHON" "$CLIF_VIRTUALENV"

# Older pip and setuptools can fail.
#
# Regardless, *necessary* on systems with older pip and setuptools.  comment
# these out if they cause you trouble.  if the final pip install fails, you
# may need a more recent pip and setuptools.
sudo "$CLIF_PIP" install --upgrade pip
sudo "$CLIF_PIP" install --upgrade setuptools

# Download, build and install LLVM and Clang (needs a specific revision).

mkdir -p "$LLVM_DIR"
cd "$LLVM_DIR"

if [ ! -f llvm-307315.tar.gz ]; then
    curl https://users.flatironinstitute.org/~rblackwell/llvm-307315.tar.gz -o llvm-307315.tar.gz
    tar -xzf llvm-307315.tar.gz
fi
cd llvm/tools
ln -s -f -n "$CLIFSRC_DIR/clif" clif

# Build and install the CLIF backend.  Our backend is part of the llvm build.
# NOTE: To speed up, we build only for X86. If you need it for a different
# arch, change it to your arch, or just remove the =X86 line below.

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
CC=clang CXX=clang++ cmake -DCMAKE_INSTALL_PREFIX="$CLIF_VIRTUALENV/clang" \
  -DCMAKE_PREFIX_PATH="$PROTOC_PREFIX_PATH" \
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=true \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_BUILD_DOCS=false \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  "${CMAKE_G_FLAGS[@]}" "$LLVM_DIR/llvm"
ninja clif-matcher clif_python_utils_proto_util
sudo "$(which ninja)" "${MAKE_INSTALL_PARALLELISM[@]}" install

# Get back to the CLIF Python directory and have pip run setup.py.

cd "$CLIFSRC_DIR"
# Grab the python compiled .proto
cp "$BUILD_DIR/tools/clif/protos/ast_pb2.py" clif/protos/
# Grab CLIF generated wrapper implementation for proto_util.
cp "$BUILD_DIR/tools/clif/python/utils/proto_util.cc" clif/python/utils/
cp "$BUILD_DIR/tools/clif/python/utils/proto_util.h" clif/python/utils/
cp "$BUILD_DIR/tools/clif/python/utils/proto_util.init.cc" clif/python/utils/
CPLUS_INCLUDE_PATH=$INSTALL_DIR/include sudo "$CLIF_PIP" install .


echo "SUCCESS - To use pyclif, run $CLIF_VIRTUALENV/bin/pyclif."
