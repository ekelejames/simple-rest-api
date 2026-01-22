# Task API - Quick User Guide

## Get Your External IP

First, check your LoadBalancer's external IP:
```bash
kubectl get service task-api-service
```

Look for the `EXTERNAL-IP` column. Example output:
```
NAME               TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)
task-api-service   LoadBalancer   10.96.16.213   172.21.255.200   80:32680/TCP
```

Your base URL will be: `http://<EXTERNAL-IP>`

**Note:** The external IP varies by cluster. Replace `172.21.255.200` in examples below with your actual IP.

## Base URL Example
```
http://172.21.255.200
```

## API Endpoints

### 1. Health Check
```bash
curl http://172.21.255.200/health
```

### 2. Get All Tasks
```bash
curl http://172.21.255.200/tasks
```

### 3. Get Single Task
```bash
curl http://172.21.255.200/tasks/1
```

### 4. Create Task
```bash
curl -X POST http://172.21.255.200/tasks \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Complete DevOps Challenge",
    "description": "Build REST API with K8s deployment",
    "status": "in-progress"
  }'
```

### 5. Update Task
```bash
curl -X PUT http://172.21.255.200/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Updated Title",
    "description": "Updated description",
    "status": "completed"
  }'
```

### 6. Delete Task
```bash
curl -X DELETE http://172.21.255.200/tasks/1
```

## Task Status Options
- `pending`
- `in-progress`
- `completed`

## Response Format
All endpoints return JSON:
```json
{
  "id": 1,
  "title": "Task title",
  "description": "Task description",
  "status": "in-progress",
  "created_at": "2026-01-22T05:25:42"
}
```

## Quick Test
```bash
# Create a task
curl -X POST http://172.21.255.200/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "Test Task", "status": "pending"}'

# View all tasks
curl http://172.21.255.200/tasks

# Update task ID 1
curl -X PUT http://172.21.255.200/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{"status": "completed"}'

# Delete task ID 1
curl -X DELETE http://172.21.255.200/tasks/1
```