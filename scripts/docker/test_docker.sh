#!/bin/bash
set -e

echo "🐳 Testing OmniVoice Server Docker Setup"
echo "========================================"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Check if image exists
echo -e "\n${YELLOW}Test 1: Checking Docker image...${NC}"
if docker images | grep -q "omnivoice-server"; then
    echo -e "${GREEN}✓ Docker image found${NC}"
else
    echo -e "${RED}✗ Docker image not found${NC}"
    exit 1
fi

# Test 2: Start container
echo -e "\n${YELLOW}Test 2: Starting container...${NC}"
docker-compose up -d
sleep 10

# Test 3: Check container is running
echo -e "\n${YELLOW}Test 3: Checking container status...${NC}"
if docker-compose ps | grep -q "Up"; then
    echo -e "${GREEN}✓ Container is running${NC}"
else
    echo -e "${RED}✗ Container is not running${NC}"
    docker-compose logs
    exit 1
fi

# Test 4: Health check
echo -e "\n${YELLOW}Test 4: Testing health endpoint...${NC}"
for i in {1..30}; do
    if curl -sf http://localhost:8880/health > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Health check passed${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}✗ Health check failed after 30 attempts${NC}"
        docker-compose logs
        exit 1
    fi
    echo "Waiting for server to be ready... ($i/30)"
    sleep 2
done

# Test 5: Test basic TTS
echo -e "\n${YELLOW}Test 5: Testing TTS endpoint...${NC}"
curl -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "omnivoice",
    "input": "Hello from Docker!",
    "voice": "auto"
  }' \
  --output /tmp/docker_test.wav \
  --silent --show-error

if [ -f /tmp/docker_test.wav ] && [ -s /tmp/docker_test.wav ]; then
    SIZE=$(stat -f%z /tmp/docker_test.wav 2>/dev/null || stat -c%s /tmp/docker_test.wav)
    echo -e "${GREEN}✓ TTS test passed (output: ${SIZE} bytes)${NC}"
    rm /tmp/docker_test.wav
else
    echo -e "${RED}✗ TTS test failed${NC}"
    docker-compose logs
    exit 1
fi

# Test 6: Check logs
echo -e "\n${YELLOW}Test 6: Checking logs...${NC}"
docker-compose logs --tail=20

# Cleanup
echo -e "\n${YELLOW}Cleaning up...${NC}"
docker-compose down
echo -e "${GREEN}✓ Cleanup complete${NC}"

echo -e "\n${GREEN}========================================"
echo -e "All Docker tests passed! ✓${NC}"
