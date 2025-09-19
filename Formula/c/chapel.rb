class Chapel < Formula
  include Language::Python::Shebang

  desc "Programming language for productive parallel computing at scale"
  homepage "https://chapel-lang.org/"
  url "https://github.com/chapel-lang/chapel/releases/download/2.6.0/chapel-2.6.0.tar.gz"
  sha256 "e469c35be601cf1f59af542ab885e8a14aa2b087b79af0d5372a4421976c74b6"
  license "Apache-2.0"
  head "https://github.com/chapel-lang/chapel.git", branch: "main"

  no_autobump! because: :bumped_by_upstream

  bottle do
    sha256 arm64_sequoia: "3c56855c59c61a8e2da5357d514d6328952036e8757b533356395b33d005be11"
    sha256 arm64_sonoma:  "7b539533e13df72b8547538aac9939ec6d71bdd0a1490cc77599f64930518fdf"
    sha256 sonoma:        "b1c6c9e5501bccabea3d743cf457fc61a04bc87b22300fa670dee36b8e5d4bfe"
    sha256 arm64_linux:   "318d08fae4535e84d1fd2db03d039f13ec2b2e52098f0d3c7ec6b5c1a0124235"
    sha256 x86_64_linux:  "2764a3159629e1848b83e1211e0b6add1f37bef7d9786de79ed6cb13141e4ccd"
  end

  depends_on "cmake"
  depends_on "gmp"
  depends_on "hwloc"
  depends_on "jemalloc"
  depends_on "llvm@20"
  depends_on "pkgconf"
  depends_on "python@3.13"

  def llvm
    deps.map(&:to_formula).find { |f| f.name.match? "^llvm" }
  end

  # determine the C backend to use based on the system
  def cbackend
    on_macos do
      return "clang"
    end
    on_linux do
      return "gnu"
    end
  end

  def install
    # Always detect Python used as dependency rather than needing aliased Python formula
    python = "python3.13"
    # It should be noted that this will expand to: 'for cmd in python3.13 python3 python python2; do'
    # in our find-python.sh script.
    inreplace "util/config/find-python.sh", /^(for cmd in )(python3 )/, "\\1#{python} \\2"

    # a lot of scripts have a python3 or python shebang, which does not point to python3.12 anymore
    Pathname.glob("**/*.py") do |pyfile|
      rewrite_shebang detected_python_shebang, pyfile
    end

    libexec.install Dir["*"]
    # Chapel uses this ENV to work out where to install.
    ENV["CHPL_HOME"] = libexec
    ENV["CHPL_GMP"] = "system"

    # This ENV avoids a problem where cmake cache is invalidated by subsequent make calls
    ENV["CHPL_CMAKE_USE_CC_CXX"] = "1"
    ENV["CHPL_CMAKE_PYTHON"] = python

    # This ENV avoids issues with GASNet picking up the wrong linker
    ENV["CHPL_IGNORE_GASNET_LD"] = "1"

    # don't try to set CHPL_LLVM_GCC_PREFIX since the llvm
    # package should be configured to use a reasonable GCC
    (libexec/"chplconfig").write <<~EOS
      CHPL_RE2=bundled
      CHPL_GMP=system
      CHPL_TARGET_MEM=jemalloc
      CHPL_TARGET_JEMALLOC=system
      CHPL_HWLOC=system
      CHPL_LLVM=system
      CHPL_LLVM_CONFIG=#{llvm.opt_bin}/llvm-config
      CHPL_LLVM_GCC_PREFIX=none
      CHPL_TARGET_CPU=native
    EOS
    # NOTE: CHPL_TARGET_CPU=native could cause problems for users cross-compiling,
    # should we only set this for CHPL_COMM=none?

    # Must be built from within CHPL_HOME to prevent build bugs.
    # https://github.com/Homebrew/legacy-homebrew/pull/35166
    cd libexec do
      system "./util/printchplenv", "--all"
      system "make"
      with_env(CHPL_TARGET_COMPILER: cbackend) do
        system "make"
      end
      with_env(
        CHPL_COMM:               "gasnet",
        CHPL_COMM_SUBSTRATE:     "udp",
        CHPL_GASNET_CFG_OPTIONS: "--disable-auto-conduit-detect --enable-udp --enable-smp",
      ) do
        system "make"
        with_env(CHPL_TARGET_COMPILER: cbackend) do
          system "make"
        end
      end
      with_env(
        CHPL_COMM:               "gasnet",
        CHPL_COMM_SUBSTRATE:     "smp",
        CHPL_GASNET_CFG_OPTIONS: "--disable-auto-conduit-detect --enable-udp --enable-smp",
      ) do
        system "make"
        with_env(CHPL_TARGET_COMPILER: cbackend) do
          system "make"
        end
      end
      with_env(CHPL_LOCALE_MODEL: "gpu", CHPL_GPU: "cpu") do
        system "make"
      end

      with_env(CHPL_PIP_FROM_SOURCE: "1") do
        system "make", "chpldoc"
        system "make", "chplcheck"
        system "make", "chpl-language-server"
      end
      system "make", "mason"
      system "make", "cleanall"

      rm_r("third-party/llvm/llvm-src/")
      rm_r("third-party/gasnet/gasnet-src/")
      rm_r("third-party/libfabric/libfabric-src/")
      rm_r("third-party/libunwind/libunwind-src/")
      rm_r("third-party/gmp/gmp-src/")
      rm_r("third-party/qthread/qthread-src/")

      #
      # the following makes sure GASNet doesn't pickup incorrect paths during the build
      #
      # clobber the gasnet include
      rm_r Dir.glob("third-party/gasnet/install/**/include")
      # clobber GASNET_CC=, GASNET_CXX=, and GASNET_LD= from the *.pc files
      gasnet_pc_files = Dir.glob("third-party/gasnet/install/**/lib/pkgconfig/gasnet-*-par.pc")
      gasnet_pc_files.each do |pc_file|
        inreplace pc_file, /^GASNET_CC=.*$/, ""
        inreplace pc_file, /^GASNET_CXX=.*$/, ""
        inreplace pc_file, /^GASNET_LD=.*$/, ""
      end
      # remove the gasnet_tools-par.pc files
      rm_r Dir.glob("third-party/gasnet/install/**/lib/pkgconfig/gasnet_tools-par.pc")
    end

    # Install chpl and other binaries (e.g. chpldoc) into bin/ as exec scripts.
    platform = if OS.linux? && Hardware::CPU.is_64_bit?
      "linux64-#{Hardware::CPU.arm? ? "aarch64" : Hardware::CPU.arch}"
    else
      "#{OS.kernel_name.downcase}-#{Hardware::CPU.arch}"
    end

    bin.install libexec.glob("bin/#{platform}/*")
    bin.env_script_all_files libexec/"bin"/platform, CHPL_HOME: libexec, CHPL_IGNORE_GASNET_LD: 1
    man1.install_symlink libexec.glob("man/man1/*.1")
    (lib/"cmake/chpl").install libexec.glob("lib/cmake/chpl/*")

    chplrun_udp = libexec/"bin"/platform/"chplrun-udp"
    chplrun_udp.write <<~EOS
      #!/bin/bash
      GASNET_SPAWNFN=L \
      GASNET_ROUTE_OUTPUT=0 \
      GASNET_QUIET=Y \
      GASNET_MASTERIP=127.0.0.1 \
      GASNET_WORKERIP=127.0.0.0 \
      CHPL_RT_OVERSUBSCRIBED=yes \
      exec "$@"
    EOS
    chplrun_udp.chmod 0755
    bin.install_symlink chplrun_udp => "chplrun-udp"
  end

  def post_install
    ohai "Chapel has been installed successfully!"
    puts <<~EOS
      By default, compiled Chapel programs will be single-locale only. There are
      two ways to compile and run multi-locale Chapel programs locally:

      Compile your program with:
        `chpl --comm=gasnet --comm-substrate=smp`

      OR

      Compile your program with:
        `chpl --comm=gasnet --comm-substrate=udp`
      And then run it with:
        `chplrun-udp ./your_program_name`

      To simulate GPU execution, you can compile your program with:
        `chpl --locale-model=gpu --gpu=cpu`
    EOS
  end

  test do
    ENV["CHPL_HOME"] = libexec
    ENV["CHPL_INCLUDE_PATH"] = HOMEBREW_PREFIX/"include"
    ENV["CHPL_LIB_PATH"] = HOMEBREW_PREFIX/"lib"
    ENV["CHPL_IGNORE_GASNET_LD"] = "1"
    cd libexec do
      system "util/test/checkChplInstall"
      system "util/test/checkChplDoc"
      with_env(CHPL_TARGET_COMPILER: cbackend) do
        system "util/test/checkChplInstall"
      end
      with_env(CHPL_COMM: "gasnet", CHPL_COMM_SUBSTRATE: "udp") do
        with_env(
          GASNET_SPAWNFN:         "L",
          GASNET_ROUTE_OUTPUT:    "0",
          GASNET_QUIET:           "Y",
          GASNET_MASTERIP:        "127.0.0.1",
          GASNET_WORKERIP:        "127.0.0.0",
          CHPL_RT_OVERSUBSCRIBED: "yes",
        ) do
          system "util/test/checkChplInstall"
          with_env(CHPL_TARGET_COMPILER: cbackend) do
            system "util/test/checkChplInstall"
          end
        end
      end
      with_env(CHPL_COMM: "gasnet", CHPL_COMM_SUBSTRATE: "smp") do
        system "util/test/checkChplInstall"
        with_env(CHPL_TARGET_COMPILER: cbackend) do
          system "util/test/checkChplInstall"
        end
      end
      with_env(CHPL_LOCALE_MODEL: "gpu", CHPL_GPU: "cpu") do
        system "util/test/checkChplInstall"
      end
    end
    system bin/"chpl", "--print-passes", "--print-commands", libexec/"examples/hello.chpl"
    system bin/"chpl", "--target-compiler", cbackend, "--print-passes",
           "--print-commands", libexec/"examples/hello.chpl"
    system bin/"chpldoc", "--version"
    system bin/"mason", "--version"

    # Test chplcheck, if it works CLS probably does too.
    # chpl-language-server will hang indefinitely waiting for a LSP client
    system bin/"chplcheck", "--list-rules"
    system bin/"chplcheck", libexec/"examples/hello.chpl"
  end
end
