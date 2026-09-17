import 'dotenv/config';

import express from 'express';
import multer from 'multer';
import { connect } from './db';
import { createEvent, getEvent } from './controllers/events.controller';
import { finishEvent, uploadPhoto } from './controllers/photos.controller';

const port = process.env.PORT || 3000;

// La foto llega en memoria porque antes de guardarla hay que reducirla y hacer la polaroid
const upload = multer({ storage: multer.memoryStorage() });

const app = express();
app.use(express.json());

app.get('/health', (req, res) => {
    res.send('OK');
});

app.post('/events', createEvent);
app.get('/events/:event_id', getEvent);
app.post('/upload', upload.single('photo'), uploadPhoto);
app.post('/finish', finishEvent);

// Las credenciales de RDS se leen de Secrets Manager al arrancar
connect()
    .then(() => {
        console.log('Conectado a la base de datos');
        app.listen(port, () => console.log(`Servidor en http://localhost:${port}`));
    })
    .catch((error) => {
        console.error('Error conectando a la base de datos:', error);
    });
