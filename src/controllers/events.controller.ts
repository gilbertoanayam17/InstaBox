import { randomUUID } from 'crypto';
import { Request, Response } from 'express';
import { query } from '../db';
import { HttpStatus } from '../types/http-status';

// POST /events -> guarda el evento en RDS y regresa el event_id generado
export async function createEvent(req: Request, res: Response) {
    const { client_name, event_type, event_date } = req.body;

    if (!client_name || !event_type || !event_date) {
        return res.status(HttpStatus.BAD_REQUEST).json({
            message: 'Faltan campos: client_name, event_type y event_date.',
        });
    }

    try {
        const event_id = randomUUID();

        await query('INSERT INTO events (event_id, client_name, event_type, event_date) VALUES ($1, $2, $3, $4)', [
            event_id,
            client_name,
            event_type,
            event_date,
        ]);

        return res.status(HttpStatus.CREATED).json({ message: 'Evento creado', event_id: event_id });
    } catch (error) {
        return res.status(HttpStatus.INTERNAL_SERVER_ERROR).json({ message: 'Error creando el evento', error: error });
    }
}

// GET /events/:event_id -> metadata del evento y cuántas fotos tiene
export async function getEvent(req: Request, res: Response) {
    const event_id = req.params.event_id;

    try {
        const events = await query('SELECT * FROM events WHERE event_id = $1', [event_id]);
        const event = events.rows[0];

        if (!event) {
            return res.status(HttpStatus.NOT_FOUND).json({ message: 'No existe ese evento' });
        }

        const photos = await query('SELECT COUNT(*) FROM photos WHERE event_id = $1', [event_id]);

        return res.status(HttpStatus.OK).json({ ...event, photo_count: Number(photos.rows[0].count) });
    } catch (error) {
        return res
            .status(HttpStatus.INTERNAL_SERVER_ERROR)
            .json({ message: 'Error consultando el evento', error: error });
    }
}
