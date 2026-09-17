import { randomUUID } from 'crypto';
import { Readable } from 'stream';
import { DeleteObjectsCommand, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import archiver from 'archiver';
import { Request, Response } from 'express';
import { query } from '../db';
import { BUCKET, s3 } from '../s3';
import { makePolaroid, resize128 } from '../polaroid';
import { HttpStatus } from '../types/http-status';

// POST /upload -> sube la foto reducida y la polaroid a S3 y guarda el registro en RDS
export async function uploadPhoto(req: Request, res: Response) {
    const { event_id, message } = req.body;
    const file = req.file;

    if (!event_id || !message || !file) {
        return res.status(HttpStatus.BAD_REQUEST).json({ message: 'Faltan datos: event_id, message y photo.' });
    }

    try {
        const events = await query('SELECT event_id FROM events WHERE event_id = $1', [event_id]);

        if (!events.rows[0]) {
            return res.status(HttpStatus.NOT_FOUND).json({ message: 'No existe ese evento' });
        }

        // Nombre único para las dos versiones de la foto
        const photo_id = randomUUID();
        const picture_key = `pictures/${photo_id}.jpg`;
        const polaroid_key = `polaroids/${photo_id}.jpg`;

        const picture = await resize128(file.buffer);
        const polaroid = await makePolaroid(file.buffer, message);

        await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: picture_key, Body: picture }));
        await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: polaroid_key, Body: polaroid }));

        await query(
            'INSERT INTO photos (photo_id, event_id, message, picture_key, polaroid_key) VALUES ($1, $2, $3, $4, $5)',
            [photo_id, event_id, message, picture_key, polaroid_key],
        );

        return res.status(HttpStatus.CREATED).json({ message: 'Foto guardada', photo_id, picture_key, polaroid_key });
    } catch (error) {
        return res.status(HttpStatus.INTERNAL_SERVER_ERROR).json({ message: 'Error subiendo la foto', error: error });
    }
}

// POST /finish -> arma el zip con las polaroids del evento y borra las fotos originales
export async function finishEvent(req: Request, res: Response) {
    const { event_id } = req.body;

    if (!event_id) {
        return res.status(HttpStatus.BAD_REQUEST).json({ message: 'Falta el event_id' });
    }

    try {
        const photos = await query('SELECT * FROM photos WHERE event_id = $1 ORDER BY created_at', [event_id]);

        if (photos.rows.length === 0) {
            return res.status(HttpStatus.NOT_FOUND).json({ message: 'El evento no tiene fotos' });
        }

        // Las fotos originales se eliminan al final mientras que las polaroids se conservan.
        const originales = photos.rows
            .filter((photo) => photo.picture_key)
            .map((photo) => ({ Key: photo.picture_key }));

        if (originales.length > 0) {
            await s3.send(new DeleteObjectsCommand({ Bucket: BUCKET, Delete: { Objects: originales } }));
            await query('UPDATE photos SET picture_key = NULL WHERE event_id = $1', [event_id]);
        }

        await query("UPDATE events SET status = 'finished' WHERE event_id = $1", [event_id]);

        // Aquí la respuesta es el archivo, ya no JSON
        res.attachment(`instabox-${event_id}.zip`);

        const zip = archiver('zip');
        zip.pipe(res);

        for (const photo of photos.rows) {
            const objeto = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: photo.polaroid_key }));
            zip.append(objeto.Body as Readable, { name: `${photo.photo_id}.jpg` });
        }

        await zip.finalize();
    } catch (error) {
        console.error(error);
        return res.status(HttpStatus.INTERNAL_SERVER_ERROR).json({ message: 'Error finalizando el evento' });
    }
}
