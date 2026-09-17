import { Pool } from 'pg';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';

let pool: Pool;

// Lee usuario y contraseña de RDS desde Secrets Manager y abre la conexión
// El cliente se crea sin credenciales, en EC2 el SDK usa el instance profile
export async function connect() {
    const secrets = new SecretsManagerClient({ region: process.env.AWS_REGION });
    const secret = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ID }));
    // El secret que crea RDS trae todos los datos de la conexión, no solo usuario y contraseña
    const { username, password, host, port, dbname } = JSON.parse(secret.SecretString!);

    pool = new Pool({
        host: host ?? process.env.DB_HOST,
        port: Number(port ?? process.env.DB_PORT ?? 5432),
        database: dbname ?? process.env.DB_NAME,
        user: username,
        password: password,
        ssl: process.env.DB_SSL === 'false' ? undefined : { rejectUnauthorized: false },
    });

    await createTables();
}

// Se relacionan por event_id
async function createTables() {
    await pool.query(`
        CREATE TABLE IF NOT EXISTS events (
            event_id    UUID PRIMARY KEY,
            client_name VARCHAR(120) NOT NULL,
            event_type  VARCHAR(60)  NOT NULL,
            event_date  DATE         NOT NULL,
            status      VARCHAR(20)  NOT NULL DEFAULT 'open',
            created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS photos (
            photo_id     UUID PRIMARY KEY,
            event_id     UUID        NOT NULL REFERENCES events(event_id),
            message      TEXT        NOT NULL,
            picture_key  TEXT,
            polaroid_key TEXT        NOT NULL,
            created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
        );
    `);
}

export function query(sql: string, params: unknown[] = []) {
    return pool.query(sql, params);
}
