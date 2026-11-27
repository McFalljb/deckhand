// typebox comes with pi, not with this folder: imported before the extensions, this stands in for
// it with the same shapes (Type.Object, Type.String, Type.Optional), for the antigravity tool's schema.
import { registerHooks } from "node:module";

const TYPEBOX = "export const Type = { Object: (properties) => ({ type: 'object', properties }), String: (o = {}) => ({ type: 'string', ...o }), Optional: (x) => x };";
registerHooks({ resolve: (spec, ctx, next) => (spec === "typebox" ? { url: `data:text/javascript,${encodeURIComponent(TYPEBOX)}`, shortCircuit: true } : next(spec, ctx)) });
