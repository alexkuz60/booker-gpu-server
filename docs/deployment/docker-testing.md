# Docker Testing Guide

Quick reference for testing Docker deployment locally.

## Quick Test

```bash
./scripts/docker/test_docker.sh
```

## Manual Steps

1. **Build**: `docker build -t omnivoice-server:test .` (3-5 min)
2. **Run**: `docker-compose up -d`
3. **Health**: `curl http://localhost:8880/health`
4. **Test TTS**: 
   ```bash
   curl -X POST http://localhost:8880/v1/audio/speech \
     -H "Content-Type: application/json" \
     -d '{"model":"omnivoice","input":"Hello!","voice":"auto"}' \
     --output test.wav
   ```
5. **Stop**: `docker-compose down`

## Troubleshooting

- **Build fails**: `docker system prune -a` to free space
- **Port conflict**: Change port in docker-compose.yml
- **Memory**: Increase Docker memory to 4GB minimum
- **Slow**: First run downloads model (~3GB), subsequent runs are faster

See full guide in repository for detailed testing procedures.
