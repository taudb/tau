# τ (tau)

> An immutable, append-only, event-sourced temporal database built in Zig

```bash 
  █████                        
 ░░███                         
 ███████    ██████   █████ ████
░░░███░    ░░░░░███ ░░███ ░███ 
  ░███      ███████  ░███ ░███ 
  ░███ ███ ███░░███  ░███ ░███ 
  ░░█████ ░░████████ ░░████████
   ░░░░░   ░░░░░░░░   ░░░░░░░░ 
```

## Why another database

Traditional databases struggle with time-series data. They force you to choose between:
- **Performance** (fast writes, slow historical queries)
- **Storage efficiency** (duplicate data, expensive history)
- **Data integrity** (mutation risks, audit nightmares)

Tau eliminates these trade-offs by fundamentally rethinking how temporal data should be stored and queried.

**Built for problems like:**
- **IoT sensor networks** storing millions of readings
- **Financial systems** requiring perfect audit trails and historical modelling 
- **Analytics platforms** needing point-in-time snapshots
- **Gaming leaderboards** with historical rankings

## Features

###  Immutable Event Sourcing
Every change is stored as a **delta** with a time range. Data is never mutated—only new deltas are appended. This gives you:
- **Perfect audit trails** by design
- **Zero corruption risk** from concurrent writes
- **Natural replication** and conflict resolution

### Smart Delta Compression
Instead of storing full states, Tau stores only what changed:
```zig
// Instead of storing temperature every second:
time: 1000s → temp: 22.1°C
time: 1001s → temp: 22.1°C  // Duplicate!
time: 1002s → temp: 22.2°C

// Tau stores numeric deltas:
temp: 22.1, valid: [1000s, 1002s)  // Base temperature
temp: 0.1,   valid: [1002s, ∞)   // Temperature change
```

### Lenses
Define reusable transformations that act as both:
- **Views** (real-time derived data)
- **Migrations** (schema evolution without data loss)

## Architecture

### Core Concepts

#### **Tau** 
A single delta representing a change valid for a specific time range.
```zig
Tau {
    id: "temp_sensor_001_2024-01-15",
    diff: 2.3,  // Numeric delta (+2.3°C change)
    valid_from: 1705123200,  // Unix timestamp
    valid_until: 1705134000  // Optional: null = still valid
}
```

#### **Schedule**
An ordered collection of related Taus (think: "temperature readings from sensor #42").

#### **Frame** 
A set of schedules that belong together (think: "all sensor data from device A").

#### **Lens**
A transformation function applied to a schedule which can act as a view or migration. 

## Getting Started

### Installation
```bash
git clone https://github.com/bxrne/tau.git
cd tau
zig build
zig build run  # Starts server on localhost:8080
```

### Basic Usage
```zig
const tau = @import("tau");

// Create a new schedule for temperature readings
var temp_schedule = try Schedule.create("iot_device_42_temperature");

// Add temperature readings (now with numeric diffs)
try temp_schedule.addTau(.{
    .diff = 22.1,  // Base temperature
    .valid_from = 1705123200,
    .valid_until = 1705126800
});

try temp_schedule.addTau(.{
    .diff = 0.1,    // Temperature increase
    .valid_from = 1705126800, 
    .valid_until = 1705130400
});

// Query state at specific time
const state = try temp_schedule.getStateAt(1705125000);
// Returns: 22.1

// Apply a lens for moving average
const avg_schedule = try temp_schedule.applyLens(moving_average, 5);
```

### Server Usage
The tau server provides a network API for remote operations:
```bash
# Start server
zig build run

# Client operations (protocol TBD, planned: HTTP/REST, gRPC)
curl -X POST http://localhost:8080/schedules \
  -d '{"name": "sensor_data", "description": "IoT readings"}'

curl -X POST http://localhost:8080/schedules/sensor_data/taus \
  -d '{"diff": 1.5, "valid_from": 1705123200}'
```


