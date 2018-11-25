# The Standard Library Build Tool

Building complex libraries and executables by invoking gxc quickly gets tedious. When you reach that point of complexity when you need a build tool, you can use the std/make library module which provides a modest build tool that can handle reasonably complex project building.

# The project source code

For illustration purposes, we'll make a hello world library module and an executable that uses it.

```
$ cat gerbil.pkg
(package: example)

$ cat util.ss
(export #t)
(def (hello who)
  (displayln "hello, " who))

$ cat hello.ss
(import :example/util)
(export main)

(def (main . args)
  (for-each hello args))
```

## The build script

This is a full fledged build script that can handle building our library and executable. It also supports dependency tracking for compiling in the correct order and incremental compilation that only compiles when relevant source modules are newer than compiled artifacts.
```
$ cat build.ss
#!/usr/bin/env gxi

(import :std/make)

;; the build specification
(def build-spec
  '("util"
    (exe: "hello")))

;; the source directory anchor
(def srcdir
  (path-normalize (path-directory (this-source-file))))

;; the main function of the script
(def (main . args)
  (match args
    ;; this action computes the dependency graph for the project
    (["deps"]
     (cons-load-path srcdir)
     (let (build-deps (make-depgraph/spec build-spec))
       (call-with-output-file "build-deps" (cut write build-deps <>))))

    ;; this is the default action, builds the project using the depgraph produced by deps
    ([]
     (let (depgraph (call-with-input-file "build-deps" read))
       (make srcdir: srcdir          ; source anchor
             bindir: srcdir          ; where to place executables; default is GERBIL_PATH/bin
             optimize: #t            ; enable optimizations
             debug: 'src             ; enable debugger introspection
             static: #f              ; don't generate static compilation artifacts
             depgraph: depgraph      ; use the depency graph
             prefix: "example"       ; this matches your package prefix
             build-spec)))))         ; the actual build specification
```

To build our project:

```
$ chmod +x build.ss
$ ./build.ss deps
$ ./build.ss
```

After the initial dependency graph generation, we can build during development by reusing the dependency graph and simply invoking ./build.ss. You only need to generate a new depency graph if your import sets change.

## Building static executables

Static executables are simply to build:

- the executable are specified with the static-exe: build spec in place of exe:.
- the make invocation needs static: #t to be specified so that static compilation artifacts are built for modules.

However, there is a nuance: you usually don't want to build static executables with debug introspection as this will blow the executable size significantly.

Perhaps the simplest way to deal with the bloat issue is to have a separate step building the executables, while still compiling library modules with debug introspection for working in the repl.

The following build script breaks the build action into two steps, one for building library modules and another for building the executables:

```
#!/usr/bin/env gxi

(import :std/make)

;; the library module build specification
(def lib-build-spec
  '("util"))

(def bin-build-spec
  '((static-exe: "hello")))

(def deps-build-spec
  (append lib-build-spec bin-build-spec))

;; the source directory anchor
(def srcdir
  (path-normalize (path-directory (this-source-file))))

;; the main function of the script
(def (main . args)
  (match args
    ;; this action computes the dependency graph for the project
    (["deps"]
     (cons-load-path srcdir)
     (let (build-deps (make-depgraph/spec deps-build-spec))
       (call-with-output-file "build-deps" (cut write build-deps <>))))

    (["lib"]
     ;; this action builds the library modules -- with static compilation artifacts
     (let (depgraph (call-with-input-file "build-deps" read))
       (make srcdir: srcdir
             bindir: srcdir
             optimize: #t
             debug: 'src             ; enable debugger introspection for library modules
             static: #t              ; generate static compilation artifacts; required!
             depgraph: depgraph
             prefix: "example"
             lib-build-spec)))

    (["bin"]
     ;; this action builds the static executables -- no debug introspection
     (let (depgraph (call-with-input-file "build-deps" read))
       (make srcdir: srcdir
             bindir: srcdir
             optimize: #t
             debug: #f               ; no debug bloat for executables
             static: #t              ; generate static compilation artifacts; required!
             depgraph: depgraph
             prefix: "example"
             bin-build-spec)))

    ;; this is the default action, builds the project using the depgraph produced by deps
    ([]
     (main "lib")
     (main "bin"))))
```

## The Standard Build Script Template

There is a standard build script definition macro in :std/build-script, which generates a main function for package build scripts suitable for packages installable through gxpkg.

Using the template would reduce the example build script to this:

```
$ cat build.ss
#!/usr/bin/env gxi
(import :std/build-script)
(defbuild-script
  '("util"
    (exe: "hello")))
```
