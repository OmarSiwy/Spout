# ml_constraint

Contract for the refactored `ml_constraint` package.

## Files
- `config.py` — module-scoped config exports.
- `model.py` — primary model definitions and essential step comments.
- `train.py` — module training entrypoint.

## Notes
- Keep reusable utilities out of this package when they can serve multiple model families.
- Keep performance-oriented code friendly to `torch.compile` where practical.
