import repro/profile

profile "m80-plan-classifier-bucket-drift-gate":
  activity default:
    m80-drift-app
    m80-realize-app
