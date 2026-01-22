from flask import Flask, request, jsonify
from datetime import datetime
import os

app = Flask(__name__)

# In-memory task storage
tasks = {}
task_id_counter = 1

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for Kubernetes probes"""
    return jsonify({"status": "healthy", "timestamp": datetime.utcnow().isoformat()}), 200

@app.route('/tasks', methods=['GET'])
def get_tasks():
    """View all tasks"""
    return jsonify({
        "tasks": list(tasks.values()),
        "count": len(tasks)
    }), 200

@app.route('/tasks/<int:task_id>', methods=['GET'])
def get_task(task_id):
    """View a specific task"""
    task = tasks.get(task_id)
    if not task:
        return jsonify({"error": "Task not found"}), 404
    return jsonify(task), 200

@app.route('/tasks', methods=['POST'])
def create_task():
    """Create a new task"""
    global task_id_counter
    
    data = request.get_json()
    if not data or 'title' not in data:
        return jsonify({"error": "Title is required"}), 400
    
    task = {
        "id": task_id_counter,
        "title": data['title'],
        "description": data.get('description', ''),
        "status": data.get('status', 'pending'),
        "created_at": datetime.utcnow().isoformat(),
        "updated_at": datetime.utcnow().isoformat()
    }
    
    tasks[task_id_counter] = task
    task_id_counter += 1
    
    return jsonify(task), 201

@app.route('/tasks/<int:task_id>', methods=['PUT'])
def update_task(task_id):
    """Update an existing task"""
    task = tasks.get(task_id)
    if not task:
        return jsonify({"error": "Task not found"}), 404
    
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data provided"}), 400
    
    # Update fields
    if 'title' in data:
        task['title'] = data['title']
    if 'description' in data:
        task['description'] = data['description']
    if 'status' in data:
        task['status'] = data['status']
    
    task['updated_at'] = datetime.utcnow().isoformat()
    
    return jsonify(task), 200

@app.route('/tasks/<int:task_id>', methods=['DELETE'])
def delete_task(task_id):
    """Delete a task"""
    task = tasks.pop(task_id, None)
    if not task:
        return jsonify({"error": "Task not found"}), 404
    
    return jsonify({"message": "Task deleted successfully", "task": task}), 200

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port, debug=False)