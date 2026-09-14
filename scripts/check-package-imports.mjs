// Parse source without executing it. The compiler is explicit build/test tooling.
import { readFileSync } from 'node:fs';
import { createRequire, builtinModules } from 'node:module';
import path from 'node:path';
const require = createRequire(import.meta.url);
const peers = new Set(['typebox', '@earendil-works/pi-ai', '@earendil-works/pi-tui', '@earendil-works/pi-coding-agent']);
const builtins = new Set(builtinModules.map(name => name.replace(/^node:/, '')));
const fail = () => { throw new Error('Unsupported or unresolved packaged module reference'); };
try {
  if (!process.argv[2] || !path.isAbsolute(process.argv[2])) fail();
  const ts = require(process.argv[2]);
  const input = readFileSync(0);
  if (input.length > 64 * 1024 * 1024) fail();
  const files = JSON.parse(input.toString('utf8'));
  if (!files || Array.isArray(files) || typeof files !== 'object' || Object.keys(files).length > 256) fail();
  for (const [name, text] of Object.entries(files)) {
    if (!name.endsWith('.ts')) continue;
    if (typeof text !== 'string') fail();
    const source = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    if (source.parseDiagnostics.length) fail();
    function moduleTarget(node) {
      if (!node || !ts.isStringLiteralLike(node)) fail();
      const value = node.text;
      if (value.startsWith('.')) {
        if (/[\\?#]/.test(value) || !/\.[a-z0-9]+$/i.test(value)) fail();
        const target = path.posix.normalize(path.posix.join(path.posix.dirname(name), value));
        if (target.startsWith('../') || target.startsWith('/') || !Object.hasOwn(files, target)) fail();
      } else if (!(peers.has(value) || (value.startsWith('node:') && builtins.has(value.slice(5))))) fail();
    }
    function unwrap(node) {
      while (ts.isParenthesizedExpression(node) || ts.isAsExpression(node)
        || ts.isTypeAssertionExpression(node) || ts.isNonNullExpression(node)
        || ts.isSatisfiesExpression(node)) node = node.expression;
      return node;
    }
    function property(node) {
      node = unwrap(node);
      if (ts.isPropertyAccessExpression(node)) return node.name.text;
      if (ts.isElementAccessExpression(node) && ts.isStringLiteralLike(node.argumentExpression)) return node.argumentExpression.text;
    }
    function enclosing(node) {
      while (node.parent && unwrap(node.parent) === unwrap(node) && node.parent.expression === node) node = node.parent;
      return node;
    }
    function called(node) {
      node = enclosing(node);
      return node.parent && ts.isCallExpression(node.parent) && node.parent.expression === node;
    }
    function visit(node) {
      if (ts.isIdentifier(node) && node.text === 'require') {
        const outer = enclosing(node), parent = outer.parent;
        const resolvedCall = parent && (ts.isPropertyAccessExpression(parent) || ts.isElementAccessExpression(parent))
          && parent.expression === outer && property(parent) === 'resolve' && called(parent);
        const namedCall = parent && ts.isPropertyAccessExpression(parent) && parent.name === outer && called(parent);
        if (!called(node) && !resolvedCall && !namedCall) fail();
      }
      if (ts.isElementAccessExpression(node) && property(node) === 'require' && !called(node)) fail();
      if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
        if (node.moduleSpecifier) moduleTarget(node.moduleSpecifier);
        if (ts.isImportDeclaration(node) && node.moduleSpecifier?.text === 'node:module') {
          const bindings = node.importClause?.namedBindings;
          if (bindings && ts.isNamedImports(bindings) && bindings.elements.some(item => (item.propertyName ?? item.name).text === 'createRequire')) fail();
        }
      } else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
        moduleTarget(node.moduleReference.expression);
      } else if (ts.isImportTypeNode(node)) {
        if (!ts.isLiteralTypeNode(node.argument)) fail();
        moduleTarget(node.argument.literal);
      } else if (ts.isCallExpression(node)) {
        const expression = unwrap(node.expression);
        if (expression.kind === ts.SyntaxKind.ImportKeyword
          || (ts.isIdentifier(expression) && expression.text === 'require')
          || property(expression) === 'require'
          || ((ts.isPropertyAccessExpression(expression) || ts.isElementAccessExpression(expression))
            && ts.isIdentifier(unwrap(expression.expression))
            && unwrap(expression.expression).text === 'require' && property(expression) === 'resolve')) {
          moduleTarget(node.arguments[0]);
        }
        if (['eval', 'Function', 'createRequire'].includes(ts.isIdentifier(expression) ? expression.text : property(expression))) fail();
      } else if (ts.isNewExpression(node) && ts.isIdentifier(unwrap(node.expression)) && unwrap(node.expression).text === 'Function') fail();
      ts.forEachChild(node, visit);
    }
    visit(source);
  }
  process.stdout.write('Validated static packaged TypeScript module references\n');
} catch {
  process.stderr.write('Unsupported or unresolved packaged TypeScript reference or syntax\n');
  process.exitCode = 1;
}
