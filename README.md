# tau

```bash 
  █████                        
 ░░███                         
 ███████    ██████   █████ ████
░░░███░    ░░░░░███ ░░███ ░███ 
  ░███      ███████  ░███ ░███ 
  ░███ ███ ███░░███  ░███ ░███ 
  ░░█████ ░░████████ ░░████████
   ░░░░░   ░░░░░░░░   ░░░░░░░░ 

`

Append-only timeseries database written in Zig.

> Currently a work in progress

## Design 

- Immutability: data is never modified in place, state is derived from deltas.
- Delta storage: only changes (deltas) are stored, not full states.
- Time-travel: any historical state can be queried by replaying deltas up to that point.
- Append-only: new data is always written to the end of the storage.

### Data Model

- A Tau represents a delta valid for a specific time range.
- A Schedule is a labelled order of Taus. (e.g. "temperature readings") 
- A Frame is a set of schedules (e.g. "sensor data for device A").
- A Lens is a transformation applied to a schedule (e.g. "moving average over 5 readings").


