"""Entry point for the code-migration-smoke fixture."""
from smoke.greeting import greet


def main() -> None:
    print(greet("turtle"))


if __name__ == "__main__":
    main()
