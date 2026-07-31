# ObjC Bridge Loader

Frida 17 no longer exposes the Objective-C bridge in every raw
`session.create_script()` context.

The GitHub Actions workflow compiles:

```text
objc-bridge-loader.ts
  -> scripts/objc-bridge-loader.bundle.js
```

Load the compiled bundle once, then call its `execute()` RPC export to run
legacy scripts in the same JavaScript context where global `ObjC` is defined.
