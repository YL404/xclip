package main

import (
	"context"
	"log"

	"github.com/YL404/xclip/internal/core"
	"github.com/YL404/xclip/internal/service"
	"github.com/egoist/mygo"
)

func main() {
	root, err := core.LibraryRoot("")
	if err != nil {
		log.Fatal(err)
	}
	library := service.NewLibrary(root)
	mygo.Bind(library)
	watch, stopWatch := context.WithCancel(context.Background())
	defer stopWatch()
	go library.Watch(watch)
	if err := mygo.Protocol.Handle("xclip-media", service.MediaHandler(library)); err != nil {
		log.Fatal(err)
	}
	mygo.App.WhenReady(func() {
		win := mygo.NewWindow(mygo.WindowOptions{
			Title: "XClip", Width: 1440, Height: 920,
			MinWidth: 960, MinHeight: 640, URL: "/",
			BackgroundColor:      "light-dark(#f5f5f6, #161719)",
			TitleBarStyle:        mygo.TitleBarHidden,
			TrafficLightPosition: &mygo.Point{X: 8, Y: 20},
		})
		win.Center()
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
	library.Close()
}
