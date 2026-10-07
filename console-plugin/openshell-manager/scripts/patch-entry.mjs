// Parchea el plugin-entry generado por el SDK npm (que llama a
// __load_plugin_entry__, protocolo de console 4.21+) al protocolo del
// bridge de console 4.20: window.loadPluginEntry con ID "name@version".
// Se ejecuta automaticamente tras `npm run build` (postbuild).
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
const pluginID = `${pkg.consolePlugin.name}@${pkg.consolePlugin.version}`;

const dist = resolve(root, 'dist');
const entries = readdirSync(dist).filter((f) => /^plugin-entry\..*\.min\.js$/.test(f));

for (const file of entries) {
  const path = resolve(dist, file);
  const src = readFileSync(path, 'utf8');
  const from = `__load_plugin_entry__("${pkg.consolePlugin.name}",`;
  const to = `loadPluginEntry("${pluginID}",`;
  if (src.includes(from)) {
    writeFileSync(path, src.replace(from, to));
    console.log(`patched ${file}: ${from} -> ${to}`);
  } else if (src.includes(to)) {
    console.log(`patched ${file}: ya parcheado (${to})`);
  } else {
    console.warn(`patched ${file}: no se encontro el callback de entrada`);
  }
}
