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
        #expect(!pose.showsPulse)
        #expect(pose.eyeScaleY > 1)
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

    @Test func eyesKeepTheirSizeAndSitCloserTogether() {
        let originalGap = 0.34
        let reduction = 1 - TomFaceGeometry.eyeSpacingFraction / originalGap
        #expect(reduction >= 0.15)
        #expect(reduction <= 0.20)
        #expect(TomFaceGeometry.eyeWidthFraction == 0.16)
        #expect(TomFaceGeometry.eyeHeightFraction == 0.34)
        #expect(TomFaceGeometry.eyeCenterYFraction == 0.10)
    }
}
