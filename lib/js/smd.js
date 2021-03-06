var app = angular.module('smd', ['zotonic']);

app.config(function($routeProvider, $interpolateProvider) {
    $interpolateProvider.startSymbol('[[').endSymbol(']]');
    
    $routeProvider
        .when("/:page", {
            templateUrl: function(params) {
                return '/views/' + params.page + '.html';
            }
        });
});

app.filter('as_time', function() {
    return function(v) {
        if (isNaN(v)) {
            return "--";
        }

        var date = new Date(1970,0,1);
        date.setSeconds(Math.floor(v));
        return date.toTimeString().replace(/.*(\d{2}:\d{2}).*/, "$1");
    };
});

app.factory('audioSupported', function() {
    return function() {
        if (!('Audio' in window)) return false;
        if ((new Audio()).canPlayType('audio/mpeg') == "") return false;
        return true;
    };
});

app.directive('messageArea', function($timeout) {
    return {
        restrict: 'E',
        template: '<div class="message-area"></div>',
        replace: true,
        link: function(scope, elm, attrs) {
            scope.$parent.messageArea = scope;
            scope.message = function(msg, cls) {
                var el = $("<div>").text(msg);
                if (cls) el.attr("class", cls);
                el.prependTo(elm);
                $timeout(function() {
                    el.slideUp(function() { el.remove(); });
                }, 5000);
            };
        }
    };
});
              
app.factory('appSocket', function(zotonicSocket) {
    var socket = zotonicSocket('/ws');

    return function(onMessage) {
        if (typeof onMessage == 'function') {
            socket.setOnMessage(onMessage);
        }
        return socket;
    };
});

app.directive('appInit', function($location, $rootScope, appSocket, audioSupported) {
    return {
        restrict: 'E',
        link: function(scope, elm, attrs) {
            $rootScope.started = true;
            var socket = appSocket();
            if ($location.path() == '/highscore') 
                return;
            if (!audioSupported()) {
                $location.path('/unsupported');
            } else {
                socket.call('disco_init').then(function(player) {
                    if (player) {
                        $location.path('/main');
                    } else {
                        $location.path('/register');
                    }
                });
            }
        }
    };
});

app.value('idlePlayer', (function() {
    var player = new Audio();
    player.loop = true;
    player.src = '/lib/media/waiting.mp3';
    player.load();
    player.pause();
    return player;
})());

app.value('player', (function() {
    return new Audio();
})());
          
app.controller('registerCtrl', function($scope, $location, $rootScope, appSocket, idlePlayer, player) {
    
    var socket = appSocket(
        function onMessage(m) {
            console.log('got generic message', m);
        });
    
    $scope.start = function() {

        player.play(); // trigger play here because otherwise chrome blocks the play event
        idlePlayer.play();
        idlePlayer.pause();
        
        $rootScope.name = $scope.name.trim();
        socket.cast('disco_register', {name: $scope.name, user_agent: navigator.userAgent});
        $location.path('/main');
    };
});

        

app.controller('mainCtrl', function($scope, $rootScope, $location, $timeout, appSocket, player, idlePlayer) {

    window.s = $scope;
    
    $scope.score = 0;
    $scope.online_count = 0;
    
    player.addEventListener('canplay', function() {
        player.pause();
        if ($scope.status == 'buffering') {
            socket.cast('disco_buffering_done');
            console.log('buffering done');
            $scope.$apply(function() {
                $scope.bufferingDone = true;
            });
        }
    }, false);

    player.addEventListener('timeupdate', function() {
        $scope.$apply(function() {
            $scope.playback = {
                currentTime: player.currentTime,
                duration: player.duration,
                percent: Math.floor(100 * player.currentTime/player.duration)
            };

            if (player.currentTime >= player.duration*0.99 && $scope.status == 'playing') {
                console.log('Playback ended');
                $scope.status = 'waiting'; // temp status, it gets set by the server
                player.src = undefined;
                socket.cast('disco_song_end');
            }
        });
    }, false);

    var socket = appSocket(function(message) {

        if (message.message) {
            $scope.messageArea.message(message.message);
            return;
        }

        switch (message.status) {
        case 'buffering':
            console.log('buffering...');

            player.src = '/media/attachment/' + message.filename;
            $scope.bufferingDone = false;
            player.autoplay = true;
            player.load();
            
            break;
        case 'playing':
            
            if ($scope.status != 'playing') {
                //setLights(true);
                $scope.enteringCode = false;
                idlePlayer.pause();
                $scope.getReady = true;
                $timeout(function() {
                    $scope.getReady = false;
                    player.play();
                }, 2000);
                
            }
            if (!$scope.has_scored && message.has_scored) {
                $scope.enteringCode = false;
                $scope.messageArea.message("Boom!! Enjoy your dance with " + message.connected_player.name + "!");
            }
            break;

        case 'waiting':
            player.pause();
            idlePlayer.play();
            break;
        }

        if (message.status && message.status.length > 0 && message.status != 'playing') {
            setLights(false);
        }
        angular.extend($scope, message);
        
    });

    socket.setOnClose(function() {
        $scope.status = 'waiting'; // better than nothing
        
        $timeout(function() {
            console.log('Reconnecting...');
            socket.reconnect();
            socket.cast("disco_start");
        }, 3000);
    });
    
    socket.call('disco_connect').then(function(r) {
        angular.extend($scope, r);
    });

    $scope.start = function() {
        idlePlayer.play();
        player.play(); // trigger play here because otherwise chrome blocks the play event
        socket.cast('disco_start');
        console.log('start!');
        idlePlayer.pause();
    };
    
    $scope.logout = function() {
        if (confirm('This will reset your score!! Are you sure?')) {
            $rootScope.name = undefined;
            socket.call('disco_stop').then(function() {
                document.location.reload();
            });
        }
    };

    $scope.song_end = function() {
        if (confirm('Skipping a song will cost you 2 points. Are you sure?')) {
            socket.cast('disco_skip');
        }
    };

    $scope.enter = {
        code: ''
    };
    
    $scope.show_code = function() {
        alert($scope.secret_code);
    };


    $scope.enter_code = function() {
        $scope.enter.code = '';
        $scope.enteringCode = true;
        $scope.enteredCode = '';
    };

    
    $scope.submitEnterCode = function() {
        $("#enternumber").blur();
        if (!$scope.has_scored) {
            socket.call('disco_guess', {code: (''+$scope.enter.code)}).then(function(result) {
                $scope.enteringCode = false;
                if (result) {
                    $scope.messageArea.message("Match! You did it. +10 pts!");
                } else {
                    $scope.messageArea.message("No match...boo! -1 pts", "error");
                }
            });
        } else {
            $scope.enteringCode = false;
        }
    };
    
    $scope.cancelEnterCode = function() {
        $scope.enteringCode = false;
    };
    
    // $scope.enter_code = function() {
    //     if ((code=prompt('Enter the secret code of your dancing partner to earn points for both of you!\n\nOnly one of you has to the other\'s code.\n\nBut... if you enter an incorrect code, you get a penalty point.'))) {
    //         if (!$scope.has_scored) {
    //             socket.call('disco_guess', {code: code}).then(function(result) {
    //                 if (result) {
    //                     $scope.messageArea.message("Yeah!! You did it. Enjoy the rest of the song!");
    //                 } else {
    //                     $scope.messageArea.message("That was the wrong code..! boo!", "error");
    //                 }
    //             });
    //         } else {
    //             // partner has scored for this player while the dialog was open.
    //         }
    //     }
    // };

    $scope.panic = function() {
        if ((confirm('This button will reset your disco state. Use only when the interface does not respond or you think it hangs.\n\nYour score will be kept safe.'))) {
            socket.cast('disco_panic');
            setTimeout(function() {
                document.location.reload();
            }, 100);
        }
    };
    
    $scope.song_title = function() {
        if ((confirm('Revealing the title of the song will cost you 1 point.'))) {
            socket.cast('disco_reveal_title');
        }
    };

    $scope.lights = false;
    var l = null;
    
    var ci = 0;
    var colors = ["#ff0000", "#00ff00", "#ffff00", "#00ffff", "#ff00ff"];
    function nextColor() {
        var color = colors[ci];
        ci = (ci + 1) % colors.length;
        return color;
    }
    
    function blink() {
        $("div.full-page").css({backgroundColor: nextColor()});
    }
    
    $scope.toggle_lights = function() {
        setLights(!$scope.lights);
    };

    function setLights(flag) {
        $scope.lights = flag;
        if ($scope.lights) {
            if (l) clearInterval(l);
            l = setInterval(blink, 200);
        } else {
            clearInterval(l);
            $("div.full-page").css({backgroundColor: "#ffffff"});
        }
    }
});


app.controller('highscoreCtrl', function($scope, appSocket) {
    var socket = appSocket(function(message) {
        console.log(message);
        if (message.message == 'disco_highscores') {
            $scope.highscores = message.args;
        }
    });

    socket.cast('disco_attach_highscores');
});
