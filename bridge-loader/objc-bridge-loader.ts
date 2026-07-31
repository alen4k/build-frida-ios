import ObjC from "frida-objc-bridge";

/*
 * Restore the global ObjC symbol expected by legacy Frida scripts.
 *
 * Important: legacy scripts must be evaluated in this same Script context.
 * A separate session.create_script() call has an independent global object.
 */
(globalThis as any).ObjC = ObjC;

rpc.exports = {
  status() {
    return {
      bridgeLoaded: true,
      objcAvailable: ObjC.available,
      classCount: ObjC.available
        ? Object.keys(ObjC.classes).length
        : 0
    };
  },

  execute(source: string, filename: string = "legacy-script.js") {
    if (!ObjC.available) {
      throw new Error(
        "Objective-C runtime is unavailable in the target process"
      );
    }

    return Script.evaluate(filename, source);
  }
};
