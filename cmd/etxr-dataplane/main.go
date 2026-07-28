package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Tianmoy/etxr/internal/dataplane"
)

var version = "dev"

func usage() {
	fmt.Fprintf(os.Stderr, `ETXR data plane %s

Usage:
  etxr-dataplane limiter --config FILE
  etxr-dataplane meter --state FILE --usage-file FILE --xray-bin FILE [--interval 30] [--once]
  etxr-dataplane version
`, version)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	var err error
	switch os.Args[1] {
	case "limiter":
		flags := flag.NewFlagSet("limiter", flag.ContinueOnError)
		flags.SetOutput(os.Stderr)
		config := flags.String("config", "", "path to limiter JSON configuration")
		if parseErr := flags.Parse(os.Args[2:]); parseErr != nil {
			os.Exit(2)
		}
		if *config == "" || flags.NArg() != 0 {
			flags.Usage()
			os.Exit(2)
		}
		err = dataplane.RunLimiter(ctx, *config)
	case "meter":
		flags := flag.NewFlagSet("meter", flag.ContinueOnError)
		flags.SetOutput(os.Stderr)
		state := flags.String("state", "", "path to ETXR state JSON")
		usageFile := flags.String("usage-file", "", "path to usage ledger JSON")
		xrayBin := flags.String("xray-bin", "", "path to the Xray executable")
		interval := flags.Int("interval", 30, "scrape interval in seconds")
		once := flags.Bool("once", false, "scrape once and exit")
		if parseErr := flags.Parse(os.Args[2:]); parseErr != nil {
			os.Exit(2)
		}
		if *state == "" || *usageFile == "" || *xrayBin == "" ||
			*interval < 1 || flags.NArg() != 0 {
			flags.Usage()
			os.Exit(2)
		}
		err = dataplane.RunMeter(ctx, dataplane.MeterOptions{
			StatePath: *state,
			UsagePath: *usageFile,
			XrayBin:   *xrayBin,
			Interval:  time.Duration(*interval) * time.Second,
			Once:      *once,
		})
	case "version", "--version", "-version":
		fmt.Println(version)
		return
	default:
		usage()
		os.Exit(2)
	}

	if err != nil && ctx.Err() == nil {
		fmt.Fprintf(os.Stderr, "etxr-dataplane: %v\n", err)
		os.Exit(1)
	}
}
