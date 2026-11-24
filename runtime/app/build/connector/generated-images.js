import { homedir } from 'node:os';
import { basename, join, resolve, win32 } from 'node:path';
import { readRasterImagePreview } from './image-previews.js';
export function generatedImagesDirectory() {
    const codexDirectory = String(process.env.CODEX_HOME || '').trim() || join(homedir(), '.codex');
    return resolve(codexDirectory, 'generated_images');
}
export function extractGeneratedImageAttachment(value) {
    const type = String(value?.type || '');
    const extensionGeneration = type === 'Extension' && value.kind === 'image_gen.generation';
    if (extensionGeneration) {
        if (value.status !== 'completed' || value.failure)
            return undefined;
    }
    else if (!/image.?generation|generated.?image/i.test(type))
        return undefined;
    const path = [
        value.saved_path,
        value.savedPath,
        value.path,
        value.result?.saved_path,
        value.result?.savedPath,
        value.result?.path,
    ].map((candidate) => String(candidate || '').trim()).find(Boolean) || '';
    if (!path || !/\.(?:jpe?g|png|webp)$/i.test(path))
        return undefined;
    return { path, name: imageFileName(path), source: 'generated' };
}
export async function readGeneratedImagePreview(payload, options = {}) {
    const root = resolve(options.directory || generatedImagesDirectory());
    return readRasterImagePreview({
        path: payload?.path,
        allowedRoots: [root],
        errorPrefix: 'generated_image',
    });
}
function imageFileName(path) {
    return (/^[A-Za-z]:[\\/]/.test(path) || path.includes('\\') ? win32.basename(path) : basename(path))
        || 'generated-image.png';
}
