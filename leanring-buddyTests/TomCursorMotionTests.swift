//
//  TomCursorMotionTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct TomCursorMotionTests {

    @Test func fastMoveTiltsAndLooksThatWay() {
        let pose = TomCursorMotion.pose(
            velocityX: 600,
            velocityY: 0,
            activity: .idle,
            isPointing: false,
            reduceMotion: false,
            time: 1
        )
        #expect(pose.tiltDegrees > 8)
        #expect(pose.eyeOffsetX > 0.5)
        #expect(pose.scaleX > pose.scaleY)
        #expect(pose.hopOffsetY < 0)
    }

    @Test func idleVelocityCentersTheEyes() {
        let pose = TomCursorMotion.pose(
            velocityX: 10,
            velocityY: -8,
            activity: .idle,
            isPointing: false,
            reduceMotion: false,
            time: 2
        )
        #expect(pose.eyeOffsetX == 0)
        #expect(pose.eyeOffsetY == 0)
        #expect(pose.tiltDegrees == 0)
        #expect(pose.scaleX == 1)
        #expect(pose.scaleY == 1)
        #expect(pose.hopOffsetY == 0)
        #expect(pose.earFlapDegrees == TomFaceGeometry.earRestDegrees)
    }

    @Test func reduceMotionDropsDecorativeMovement() {
        let pose = TomCursorMotion.pose(
            velocityX: 800,
            velocityY: 400,
            activity: .listening,
            isPointing: true,
            reduceMotion: true,
            time: 0.02
        )
        #expect(pose.tiltDegrees == 0)
        #expect(pose.eyeOffsetX == 0)
        #expect(pose.eyeOffsetY == 0)
        #expect(pose.scaleX == 1)
        #expect(pose.scaleY == 1)
        #expect(pose.bobOffsetY == 0)
        #expect(pose.hopOffsetY == 0)
        #expect(!pose.showsPulse)
        #expect(pose.eyeScaleY > 1)
        #expect(pose.earFlapDegrees == TomFaceGeometry.earRestDegrees + TomFaceGeometry.earActiveDegrees)
    }

    @Test func listeningWidensTheEyesAndShowsAPulse() {
        let pose = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .listening,
            isPointing: false,
            reduceMotion: false,
            time: 1.0
        )
        #expect(pose.eyeScaleY > 1.2)
        #expect(pose.showsPulse)
        #expect(pose.pulseScale > 1)
    }

    @Test func thinkingLooksUpAndToTheRight() {
        let pose = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .thinking,
            isPointing: false,
            reduceMotion: false,
            time: 0.4
        )
        #expect(pose.eyeOffsetX > 0.4)
        #expect(pose.eyeOffsetY < -0.4)
        #expect(pose.bobOffsetY != 0)
    }

    @Test func blinkClosesTheEyesForAShortWindow() {
        let blinking = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .idle,
            isPointing: false,
            reduceMotion: false,
            time: 0.05
        )
        let open = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .idle,
            isPointing: false,
            reduceMotion: false,
            time: 0.4
        )
        #expect(blinking.eyeScaleY < 0.2)
        #expect(open.eyeScaleY == 1)
        #expect(!TomCursorMotion.isBlinking(time: 0.05, reduceMotion: true))
    }

    @Test func movingOrSpeakingHopsAndListeningFlapsTheEars() {
        let moving = TomCursorMotion.pose(
            velocityX: 480,
            velocityY: 0,
            activity: .idle,
            isPointing: false,
            reduceMotion: false,
            time: 0.2
        )
        let speaking = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .speaking,
            isPointing: false,
            reduceMotion: false,
            time: 0.2
        )
        let still = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .idle,
            isPointing: false,
            reduceMotion: false,
            time: 0.2
        )
        #expect(moving.hopOffsetY < 0)
        #expect(speaking.hopOffsetY < 0)
        #expect(speaking.earFlapDegrees > 10)
        #expect(still.hopOffsetY == 0)
        #expect(still.earFlapDegrees == 0)

        let early = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .listening,
            isPointing: false,
            reduceMotion: false,
            time: 0.05
        )
        let later = TomCursorMotion.pose(
            velocityX: 0,
            velocityY: 0,
            activity: .listening,
            isPointing: false,
            reduceMotion: false,
            time: 0.25
        )
        let reducedA = TomCursorMotion.flappingEarDegrees(time: 0.05, reduceMotion: true)
        let reducedB = TomCursorMotion.flappingEarDegrees(time: 0.9, reduceMotion: true)
        #expect(early.earFlapDegrees != later.earFlapDegrees)
        #expect(early.showsPulse)
        #expect(reducedA == reducedB)
        #expect(TomFaceGeometry.eyeCenterYFraction < 0)
        #expect(TomFaceGeometry.eyeWidthFraction > TomFaceGeometry.eyeHeightFraction)
    }
}
