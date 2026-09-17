import sharp from 'sharp';

// Medidas del marco Polaroid.
const PHOTO = 600;
const MARGIN = 40;
const WIDTH = PHOTO + MARGIN * 2;
const HEIGHT = MARGIN + PHOTO + 200;

// Versión reducida que se guarda en pictures/
export function resize128(original: Buffer) {
    return sharp(original).resize(128, 128, { fit: 'cover' }).jpeg().toBuffer();
}

// Marco blanco con la foto arriba y el mensaje escrito abajo
export async function makePolaroid(original: Buffer, message: string) {
    const photo = await sharp(original).resize(PHOTO, PHOTO, { fit: 'cover' }).toBuffer();

    // El mensaje se dibuja como un SVG encima del marco blanco
    const lines = cutLines(message);
    const texts = lines
        .map((line, i) => `<text x="${WIDTH / 2}" y="${MARGIN + PHOTO + 75 + i * 46}">${escapeXml(line)}</text>`)
        .join('');

    const svg = `
        <svg width="${WIDTH}" height="${HEIGHT}" xmlns="http://www.w3.org/2000/svg">
            <style>text { fill: #2b2b2b; font-family: 'DejaVu Sans', sans-serif; font-size: 34px; text-anchor: middle; }</style>
            ${texts}
        </svg>
    `;

    return sharp({ create: { width: WIDTH, height: HEIGHT, channels: 3, background: '#ffffff' } })
        .composite([
            { input: photo, top: MARGIN, left: MARGIN },
            { input: Buffer.from(svg), top: 0, left: 0 },
        ])
        .jpeg()
        .toBuffer();
}

// Parte el mensaje en renglones de máximo 30 caracteres para que no se salga del marco
function cutLines(message: string) {
    const lines: string[] = [];
    let line = '';

    for (const word of message.trim().split(' ')) {
        if ((line + ' ' + word).trim().length > 30) {
            lines.push(line);
            line = word;
        } else {
            line = (line + ' ' + word).trim();
        }
    }
    lines.push(line);

    return lines.slice(0, 3);
}

// Si el mensaje trae & o <, el SVG queda inválido y sharp truena
function escapeXml(text: string) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
