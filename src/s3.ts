import { S3Client } from '@aws-sdk/client-s3';

// Igual que Secrets Manager, sin credenciales en el código, las pone el instance profile
export const s3 = new S3Client({ region: process.env.AWS_REGION });

export const BUCKET = process.env.S3_BUCKET!;
